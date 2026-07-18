# QAttach

etcd-backed distributed lock manager (DLM) replacement for GFS2 on EBS Multi-Attach.

## Architecture

```
lock_etcd (kernel module, lm_lockops impl) ←Netlink→ cluster-agent (Go daemon) ←etcd v3→ etcd (colocated, 3-node Raft)
```

- **`lock_etcd`** — kernel module (C) implementing GFS2's `lm_lockops`. Built in-tree as part of `gfs2.ko` via `scripts/kernel/patch-kernel.py` (patches GFS2 source to call lock_etcd init/cleanup). Replaces `lock_dlm`.
- **`cluster-agent`** — Go userspace daemon (one per compute node). Handles etcd membership, fencing, Netlink server. Agent can start without the kernel module (netlink server is non-fatal).
- **etcd** — 3-node Raft cluster colocated on compute nodes. Agent manages bootstrap/join/member-remove (`internal/membership/`). No dedicated etcd instances or NLB.
- **GFS2** — unchanged on-disk format. Journals on-disk only (not in etcd).
- **EBS io2 Multi-Attach** — one volume per AZ shared by all compute nodes.

## Key constraints

- Fencing: EC2 API (`StopInstances`/`DetachVolume`), **not** STONITH/IPMI. Never grant `ec2:TerminateInstances`.
- Session lease TTL=15s, keepalive every 5s. Idle nodes are never fenced.
- Fencing token = etcd revision of the lock key, validated on every request.
- No node-to-node monitoring — etcd Watch + session expiry are the sole liveness signals.
- Glock mode mapping: EX→EX, SH→PR, DF→CW, UN→delete key.
- etcd keys: `/cluster/members/{id}`, `/cluster/fencing/{id}`, `/cluster/epoch`, `/cluster/journals/{jid}`, `/locks/glock/{type}/{number}`, `/locks/glock/{type}/{number}/next` (handoff reservation), `/locks/bast/{type}/{number}` (BAST request signal).
- `mkfs.gfs2` doesn't recognize `lock_etcd` — format with `-p lock_dlm`, mount with `-o lockproto=lock_etcd`.

## Build & test

```bash
go build ./...          # build cluster-agent (alias: make build-agent → bin/cluster-agent)
go test ./...           # 5 packages with tests (no infra needed)
go vet ./...            # static analysis
make build-module       # kernel module (requires kernel headers)
make lint               # requires golangci-lint (not in go.mod)
```

Single-package test: `go test ./internal/netlink/`

## Deployment workflow

Run in order:
```bash
# 1. Build kernel (optional — prebuilt on S3). Teardown instance after upload.
scripts/kernel/launch.sh
# 2. Provision AWS infra
QATTACH_KEY_NAME=muhamad-keypair scripts/infra/create-infra.sh
# 3. Install etcd + agent + kernel module + GFS2 on compute nodes
scripts/infra/setup-compute.sh
# 4. End-to-end test
scripts/infra/run-full-test.sh
# 5. Teardown
scripts/infra/destroy-infra.sh --force
```

Infra state saved to `infra-state.json` (gitignored). Env overrides: `QATTACH_KEY_NAME`, `QATTACH_PEM_PATH`, `QATTACH_AZ`, `QATTACH_CLUSTER`, etc. Region: `eu-west-1`, AZ: `eu-west-1b`.

## Critical gotchas

### Go struct padding for Netlink
Go netlink message structs in `pkg/protocol/netlink.go` have explicit padding fields (`PadGrant`, `PadDeny`, `PadMnt`, `Pad`) to match C struct layout in `kernel/letcd_netlink.h`. If you modify either side, check `binary.Size(T{})` matches `sizeof(struct letcd_*)`.

### Dual `letcd_netlink.h`
The Netlink protocol header is duplicated at `pkg/protocol/letcd_netlink.h` and `kernel/letcd_netlink.h`. **Keep both in sync** when adding message types or changing structs.

### Agent restart with GFS2 mounted
The cluster-agent systemd unit must **not** have `ExecStop=umount` — it bricks agent restarts (systemd tries to unmount, hangs because filesystem is busy). If GFS2 is hung, use `aws ec2 stop-instances --force` (not graceful shutdown).

### Kernel packaging
The custom kernel (6.18.35, NVMe built-in, lock_etcd in gfs2.ko) must be deployed before `setup-compute.sh`. The S3 archive may have stale `gfs2.ko` — verify the module path in the tar matches what compute nodes expect (`/lib/modules/6.18.35/` not a full distro version path).

### GFS2 reference source
The upstream GFS2 and DLM source used for analysis is at `/tmp/gfs2-src/linux/fs/gfs2/` (shallow git clone from torvalds/linux). Key files: `glock.c` (do_xmote, gfs2_glock_complete, gfs2_glock_cb, finish_xmote, state_change, run_queue), `lock_dlm.c` (gdlm_lock, gdlm_ast, gdlm_bast), `glops.c` (journal glock operations), `glock.h` (LM_ST_*, LM_FLAG_*, GLF_*), `ops_fstype.c` (gfs2_fill_super), `recovery.c` (journal recovery with LM_FLAG_TRY). The project's kernel module is built from the Amazon Linux 2023 kernel 6.18.35 SRPM, not from this reference source, but the core logic is equivalent.

## File map

| Path | Purpose |
|------|---------|
| `cmd/cluster-agent/main.go` | CLI entrypoint |
| `internal/{etcd,fencing,identity,lifecycle,lock,membership,netlink,config,signal}/` | Go agent packages |
| `pkg/protocol/` | Shared Go/C types (glock modes, Netlink messages, etcd keys) |
| `kernel/` | `lock_etcd` kernel module (C, lm_lockops impl, built into gfs2.ko) |
| `scripts/infra/` | AWS infra provisioning, etcd setup, compute setup, e2e tests |
| `scripts/kernel/` | Kernel build pipeline (`launch.sh`, `patch-kernel.py`, `teardown.sh`) |
| `docs/` | Architecture, epoch mechanism, known limitations |

## Session history — what was attempted and why

This section records every significant change made during the July 2026 debugging session, preserving the reasoning behind each attempt and its outcome. This is critical context for anyone resuming work.

### Fix 1: LockRequest struct size mismatch (commit `f26c189`) — SUCCESS, KEPT

**Problem detected**: Agent never received lock requests. Kernel sent `NL-SENT ret=0` but agent's `Serve()` goroutine stayed blocked on `recvfrom`. Debug logging revealed the kernel sent 24-byte lock request payloads, but Go's `LockRequest` struct was 32 bytes (had `NodeEpoch int64`). `binary.Read` failed silently due to EOF, `decodeLE` returned false, messages silently dropped.

**Actual root cause**: The kernel binary (built July 3) had `sizeof(letcd_lock_req)=24` — no `node_epoch` field. The field was added to the `letcd_netlink.h` source headers after the kernel was built, but not to the binary.

**Fix**: Removed `NodeEpoch int64` from Go `LockRequest` struct, removed `node_epoch` from both copies of `letcd_netlink.h`, removed `req.node_epoch` assignment from `lock_etcd_lock.c`.

### Fix 2: Lock mode constants "fix" (commit `6ebbd16`) — REVERTED (commit `73e62a7`)

**Claim in AGENTS.md**: "GFS2 kernel `LM_ST_SHARED=1`, `LM_ST_EXCLUSIVE=3`. But `pkg/protocol/glock.go` defines `LockModeExclusive=1`, `LockModeShared=3` — swapped."

**What we did**: Swapped constants to `LockModeShared=1`, `LockModeExclusive=3`.

**Why it was wrong**: Inspection of the actual GFS2 source (`/tmp/gfs2-src/linux/fs/gfs2/glock.h`) revealed:
```c
#define LM_ST_EXCLUSIVE   1
#define LM_ST_SHARED      3
```
The **original** code (`LockModeExclusive=1, LockModeShared=3`) was correct. The AGENTS.md had the values reversed. The "fix" inverted the mapping:
- GFS2 EX (mode=1) → mapped to `"PR"` (shared) in etcd
- GFS2 SH (mode=3) → mapped to `"EX"` (exclusive) in etcd

**Why the inverted mapping accidentally helped**: It turned EX locks into PR in etcd, allowing false concurrency. Two nodes could both "hold" the journal lock because it was stored as shared (PR) in etcd. This is how multi-node mount worked in v0.0.3 — it was a bug, not a feature.

**Result**: Reverted in commit `73e62a7`. Constants are now back to `EX=1, SH=3` matching GFS2.

### Fix 3: Agent-side journal lock DENY (commit `c3723f2`) — KEPT

**Purpose**: When ProcessLock returns `granted=false` for a journal lock (type=1, num>=1, EX mode), send DENY immediately instead of WAIT — don't start retry goroutine.

**Reasoning**: Journal locks held by another live node will never be released (GFS2 holds them while mounted, BAST is ignored). The kernel gets DENY → `gfs2_glock_complete(gl, -EAGAIN)` → GFS2 should skip that journal.

**Outcome**: This fix works for what it does, but GFS2 treats `-EAGAIN` as a fatal mount error, aborting the entire mount. So the DENY alone doesn't solve multi-node mount.

### Fix 4: retryProcessLock timeout (commit `c3723f2`) — KEPT

**Purpose**: Changed `retryProcessLock` to use a 120s timeout context instead of `context.Background()`. On timeout, sends DENY and cleans up waiter entry.

### Fix 5: Kernel LM_FLAG_TRY synchronous handling (commit `eefadf1`) — KEPT

**Purpose**: When GFS2 calls `lm_lock` with `LM_FLAG_TRY` or `LM_FLAG_TRY_1CB`, complete synchronously with `gfs2_glock_complete(gl, -EAGAIN)` instead of sending to the agent.

**Real GFS2 values** (from source): `LM_FLAG_TRY = 0x0001`, `LM_FLAG_TRY_1CB = 0x0002`.

**Outcome**: Never triggered in testing — GFS2's journal recovery code on this kernel version (Amazon Linux 2023 6.18.35) does not set `LM_FLAG_TRY` in the flags for journal lock requests during mount. The flags value was `0x284` which does not include `0x0001`.

### Fix 6: Kernel JRNL-DENY based on mount_jid (commit `15b833f`) — KEPT BUT INEFFECTIVE

**Purpose**: For journal locks (type=1 num>=1 EX), if `glock_number != mount_jid + 1` (i.e., this is NOT our journal), deny synchronously.

**Outcome**: Code was present in kernel binary (strings confirmed) but never executed. Likely cause: `mount_jid` read without memory barrier between the netlink handler (writer) and the lock path (reader). Even if it did fire, GFS2's `gfs2_glock_complete(gl, -EAGAIN)` causes fatal mount abort — same issue as Fix 3.

### Fix 7: gfs2_glock_complete ret=0 (commit `b50ed74`) — REVERTED

**Purpose**: Change `gfs2_glock_complete(gl, grant->granted_mode)` to `gfs2_glock_complete(gl, 0)` matching DLM's `gdlm_ast` convention.

**Why it broke**: With `ret=0`, GFS2's `do_xmote` skips the error handler and enters a path that doesn't transition `gl_state`. The glock stays at UNLOCKED and re-requests the lock infinitely. With `ret=granted_mode` (1 or 3), `do_xmote` enters the error handler for non-zero ret, which happens to promote holders correctly. Reverted.

**Key finding from DLM source analysis**: DLM's `gdlm_ast` passes `ret = gl->gl_req` (the requested LM_ST_* value, 0-3) to `gfs2_glock_complete`, not 0 and not the granted mode. DLM guarantees requested mode equals granted mode. Our code passes `grant->granted_mode` which is semantically the same (0-3). This is correct and should not be changed.

### Fix 8: LM_OUT_TRY_AGAIN for TRY handler (commit `73e62a7`) — KEPT

**Purpose**: Changed kernel TRY handler from `gfs2_glock_complete(gl, -EAGAIN)` to `gfs2_glock_complete(gl, LM_OUT_TRY_AGAIN)` (0x20).

**Why**: DLM's `gdlm_ast` uses `LM_OUT_TRY_AGAIN` (0x20) for TRY failures, not raw `-EAGAIN`. GFS2's `finish_xmote` checks `ret & ~LM_OUT_ST_MASK` (0x03 mask) — values 0-3 trigger `state_change`, values ≥4 are treated as errors. `LM_OUT_TRY_AGAIN = 0x20` correctly enters the error path (bit beyond mask set), while `-EAGAIN = -11` would be a large unsigned value that may behave unexpectedly.

### Fix 9: Script fixes (commits `9335817`, `37ac013`) — KEPT

- `wait_for_agent_ready` in `state.sh`: sanitized numeric SSH output with `tr -d '[:space:]'`
- `setup-compute.sh`: removed `noatime` mount option (GFS2 doesn't support it)
- `setup-compute.sh`: agents now start sequentially (node 0 first, wait ready, then node 1, etc.) with proper readiness checks
- `setup-compute.sh`: removed redundant gfs2 load + agent restart from non-first-node blocks
- `setup-compute.sh`: stale-clean logic only nukes etcd data when etcd is NOT running
- `server.go`: added `os.Getpid()` to nlh.Pid (harmless, may be unnecessary) and `nlh.Type = msgType` (also harmless)

### Fix 10: Always release from etcd on unlock (commit `cb0108c`) — KEPT

**Problem**: `HandleLockRelease` and `releaseHeldLock` silently returned when the lock wasn't in the agent's local `heldLocks` map. GFS2's `gfs2_glock_dq_uninit(&mount_gh)` at the end of `fill_super` triggers unlock → `lm_lock(UNLOCK)` → kernel sends `LETCD_MSG_LOCK_REL` → agent drops it because the MOUNT lock wasn't in `heldLocks`. The etcd key for the MOUNT lock persisted, blocking the second node's mount.

**Fix**: Both functions now call `ReleaseLock` on etcd even for untracked locks. The local map is just a cache — the etcd key must always be cleaned up.

**Outcome**: Multi-node mount works. All 3 nodes mount GFS2 without hacks.

### Fix 11: Always send BAST on contention (commit `c866963`) — KEPT

**Problem**: `HandleLockRequest` only sent BAST when `!wasHolder`. If a node was a PR holder and tried to upgrade to EX (PR→EX), `wasHolder=true` → BAST never sent. Meanwhile `ProcessLock` removed the node from holders (see Fix 12), so the EX holder never received a BAST and never released.

**Fix**: Removed the `!wasHolder` guard. BAST is always sent when there's contention.

**Outcome**: BASTs now fire on all contention, including PR→EX upgrade attempts. The heartbeat lock (type=2 num=50063) cycles through BAST→UNLOCK→GRANT correctly on all 3 nodes.

### Fix 12: Don't remove self from holders on EX upgrade conflict (commit `c170bfd`) — KEPT

**Problem**: `ProcessLock`'s self-contention PR→EX path: when another node held EX, the code REMOVED this node's PR entry from the holders array and returned false. The node became a "waiter" with no etcd entry. Combined with Fix 11 (BAST now sent), the node should re-acquire, but the holder removal was destructive.

**Fix**: When another node holds EX during a PR→EX upgrade, just return false. Don't mutate the etcd key. Keep the PR entry. Let the BAST mechanism cause the EX holder to release, then the retry goroutine acquires EX.

**Outcome**: Nodes stay as PR holders while waiting for EX. The etcd state is consistent.

### Fix 13: FIFO handoff — ProcessLock checks /next marker (commit `66af53f`) — KEPT

**Problem**: `HandoffRelease` atomically deletes the lock key and writes `/locks/glock/{type}/{number}/next` naming the first waiter. But `ProcessLock`'s fresh-acquisition path ignored this marker entirely. Any node could immediately re-acquire the lock by CAS'ing a new key, before the designated waiter could claim it. This caused live-lock: node 0 releases → creates handoff for node 1 → node 0 immediately re-acquires (another process on node 0 needs the lock) → node 1's handoff claim fails → node 1 retries → node 0 releases again → cycle repeats. DLM avoids this with a FIFO grant queue.

**Fix**: `ProcessLock` now checks the `/next` marker before fresh acquisition. If a marker exists naming a different node, the acquisition is refused. If the marker names this node, it's atomically deleted alongside the key creation. This enforces FIFO ordering.

**Outcome**: Handoff chain confirmed in agent logs: node0→node1→node2. The agent-side live-lock is resolved.

### Fix 14: Delete handoff marker on timeout (commit `dd6d01e`) — KEPT

**Problem**: `retryProcessLock` timeout handler removed the waiter entry but left the `/next` handoff marker intact. If the designated node timed out, the marker blocked other nodes for up to the session TTL (15s).

**Fix**: Timeout handler now calls `DeleteHandoff` to clean up the marker.

### Fix 15: Journal lock DENY for type=9 (commit `cb0108c`) — KEPT

**Problem**: The original journal lock DENY checked type=1 (NONDISK). But GFS2 journal locks are type=9 (LM_TYPE_JOURNAL). The DENY never matched.

**Fix**: Changed the check to `LockTypeJournal` (type 9) for EX mode requests. Also removed the old type=1 num>=1 check.

## Current state — what works, what doesn't, and why

### Works: Multi-node mount (3 nodes mount successfully)

Node 0 mounts → acquires MOUNT lock (type=1 num=0 EX) → mount init → releases MOUNT lock via `gfs2_glock_dq_uninit`. The release reaches the agent (via Fix 10), etcd key is cleaned. Node 1 mounts → MOUNT lock is free → acquires normally. All 3 nodes mount.

### Works: Heartbeat lock handoff (type=2 num=50063)

The heartbeat lock cycles through BAST→UNLOCK→GRANT on all 3 nodes every 30 seconds. The full handoff chain works: BAST received by kernel → `gfs2_glock_cb` → `run_queue` → `do_xmote(UNLOCKED)` → `letcd_lock(UNLOCK)` → LOCK_REL → agent HandoffRelease → etcd key deleted + /next written → waiter retry goroutine picks up handoff → acquires via ProcessLock → GRANT sent to kernel.

### Works: Agent-side FIFO ordering

`ProcessLock` now respects the `/next` handoff marker. The chain node0→handoff→node1→handoff→node2 is visible in etcd and agent logs.

### Broken: Kernel BAST not delivered for cached/freed glocks

The heartbeat lock's BAST mechanism works because the glock is always alive (re-acquired every 30s). But for inode glocks (e.g., directory inode 50069), GFS2 can free the glock from the LRU between the UNLOCK and the next re-acquisition. When `letcd_put_lock` is called during `gfs2_glock_free`, `letcd_bast_remove` removes the glock from the bast list. A subsequent BAST from another node finds no glock via `letcd_bast_lookup` → no demotion → etcd shows the old EX holder → waiters block.

Confirmed by test: directory inode SH request gets WAIT at [220ms] and never resolves. Node 0's dmesg shows no BAST, no BAST-DROPPED, no UNLOCK for 50069 — only heartbeat activity. The BAST was sent by the agent (confirmed in logs) but the kernel silently discarded it because the glock was not in the bast list.

### Why multi-node mount worked before (v0.0.3 era)

Before the lock mode "fix" was reverted, the constants were `EX=1, SH=3` (correct matching GFS2). The mount worked because:
1. MOUNT lock was released by GFS2 at the end of `fill_super` (verified from source)
2. With the original agent code (ConvertLock + watchForLock), the release was processed correctly
3. The old flow might have handled the release path differently, or the old kernel module kept glocks in the bast list longer

## Known bugs (blocking e2e)

### CRITICAL: Multi-node mount blocked — lock_etcd cannot do EX→SH mode conversion

**Root cause**: GFS2 acquires the superblock in EXCLUSIVE mode during `gfs2_fill_super`. When a second node mounts, it also requests EX on the superblock. DLM resolves this by sending a BAST that forces the first holder to **convert** EX→SH (not unlock). GFS2's `run_queue` handles this conversion via `do_xmote` with the demoted target. lock_etcd has no mode conversion support — it can only do unlock→handoff→reacquire, which is blocked by `find_first_holder()`.

**Same issue affects journal locks**: Node 0 holds its journal EX permanently. Node 1's journal recovery check tries to acquire EX on node 0's journal with `LM_FLAG_TRY`. DLM returns -EAGAIN synchronously when TRY can't be granted. Our kernel must do the same — but `LM_FLAG_TRY` is not set by GFS2 on this kernel version, and even if it were, returning -EAGAIN via `gfs2_glock_complete` causes GFS2 to abort the entire mount (not just skip the journal).

**Partial workaround applied**: Fix 10 (always release from etcd on unlock) combined with the fact that GFS2 releases the MOUNT lock at the end of fill_super means multi-node mount now works. The heartbeat lock handoff (BAST→UNLOCK→GRANT, Fixes 11-15) handles shared-resource contention for running filesystems. Light concurrent I/O works (1op/5s per node, 3 shared files). Mode conversion is still needed for the general case (EX→SH without full unlock) but the immediate blockers are resolved.

**Fix requires**: Kernel module must implement `lm_lock(gl, LM_ST_SHARED)` as a mode conversion when `gl_state == LM_ST_EXCLUSIVE`. This means:
1. Kernel detects conversion (target < current state, lock already held)
2. Agent must update the etcd key: change our entry from EX→PR in the holders array
3. BAST + yield mechanism must cause GFS2 to actually process the demotion (currently blocked by holders)

### BUG: gfs2_glock_complete called with granted_mode as ret

`dispatch_lock_grant` passes `grant->granted_mode` (1 or 3) to `gfs2_glock_complete`. DLM passes `gl->gl_req` (requested state). Both are 0-3 so functionally equivalent, but the DLM convention is clearer. Low priority — works correctly.

### BUG: Inline-SH fast-path nested inside yield-suppress block

`lock_etcd_lock.c`: The inline-SH code (types 1,5,8) is inside `if (letcd_yield_test(...))`, so it only activates when a yield flag is set. Should be moved before the yield check so it applies to ALL SH requests on those types.

### BUG: Ordered list never cleaned on unmount

`letcd_ordered_list` in `lock_etcd_lock.c` persists across mount/unmount cycles. Stale entries block subsequent lock requests. Requires `letcd_ordered_cleanup()` in `lock_etcd_unmount()`.

**Note: no trace of `letcd_ordered_list` found in current kernel source. The binary may differ. Verify with `strings gfs2.ko | grep ordered` on a compute node.**

### FIXED: Kernel BAST dropped for freed/cached glocks (Option A — commit `f786602`)

When GFS2 frees a glock from the LRU cache, `letcd_put_lock` calls `letcd_bast_remove`, removing the glock from the bast lookup list. A subsequent BAST from another node finds no glock → BAST is discarded → waiters block. Option A fixed it by removing `letcd_bast_remove` from the UNLOCK path in `letcd_lock`, keeping it only in `letcd_put_lock`. The glock stays in the bast list across UNLOCK→ACQUIRE cycles. Confirmed: BAST→UNLOCK now fires for directory inode (50069).

## Remaining todo

### Priority 1 — Code quality cleanup (Go only, no kernel rebuild)

Safe deletions — the live code paths use `ProcessLock` + `retryProcessLock` exclusively. All old yield-based helpers are superseded.

- [x] **Delete dead functions in `internal/lock/manager.go`**: `watchForLock`, `watchForConversion`, `tryAcquireAsFirstWaiter`. Superseded by `retryProcessLock`.
- [x] **Delete dead functions in `internal/etcd/client.go`**: `AcquireLock`, `ConvertLock`, `CheckHandoff`, `IsFirstWaiter`, `AmIHolder`, `firstHolderInfo`, `isHolder`. All were helpers for the old flow; handoff is now handled inline in `ProcessLock`.
- [x] **Delete unused `LockValue` struct** from `pkg/protocol/etcd.go` — lock value format changed to JSON array of `lockEntry` objects.
- [x] **Delete unused `wg sync.WaitGroup` field** from `internal/netlink/server.go` — declared but never called anywhere.
- [x] **Delete unreachable UNLOCKED branch** in `internal/lock/manager.go` — kernel never sends LOCK_REQ with mode=0; it sends LOCK_REL instead.

~310 lines removed. Build / test / vet all pass.

### Priority 2 — Agent robustness (no kernel changes)

- [x] **Fix `isEndpointHealthy` connection churn**: `waitForHealth` now creates a single persistent `clientv3.Client` for the health-check loop, reused on every tick, closed on exit. Avoids wasteful TLS handshake churn.
- [x] **Fix `hasExistingData` restart**: `Bootstrap` now checks peer reachability before writing the full `InitialCluster`. If no peers respond, only the local member is written (sole survivor restart). If at least one peer is healthy, the full cluster spec is used.
- [x] **Remove debug `netlink recv/dispatch` log lines** in `server.go`.
- [x] **Clean up `sendMsg` double-write**: removed `nlh.Type = uint16(msgType)`. Kernel reads only the body prefix for dispatch. Updated comment to reflect actual protocol.
- [x] **Remove `SendRegister` zero payload**: register message now sends only the msgType prefix (4 bytes). Kernel only checks the first 4 bytes.

### Priority 3 — Kernel correctness (requires kernel rebuild)

- [ ] **Remove yield infrastructure from kernel**: `lock_etcd_netlink.c:138-149` (dispatch), `lock_etcd_glock.c:187-262` (yield_table + set/test/clear/cleanup), and the `letcd_lock_yield` struct. Agent hasn't sent YIELD/YIELD_CLEAR since Fix 11 — BAST replaced it. **This also fixes the inline-SH issue below** (the enclosing `if (letcd_yield_test(...))` block that gates inline-SH is removed).
- [ ] **Sync `kernel/letcd_netlink.h` and `pkg/protocol/letcd_netlink.h`**: Go copy has yield messages (12, 13) and `struct letcd_lock_yield`; kernel copy doesn't. After yield removal, both should contain only messages 1-11. Verify both are identical.
- [ ] **Move inline-SH fast-path outside yield-suppress block**: `lock_etcd_lock.c:64-78` is gated on `letcd_yield_test()` at line 59, which always returns false (yield is dead). Removing the yield block naturally fixes this. If yield removal is deferred, manually extract the inline-SH code.
- [ ] **Verify `letcd_ordered_list` and add cleanup if needed**: No trace of `letcd_ordered_list` found in current kernel source. Verify with `strings gfs2.ko | grep ordered` on a compute node. If present in binary but missing from source, reconcile. If present, add `letcd_ordered_cleanup()` in `letcd_unmount()`.
- [ ] **Investigate why GFS2's Amazon Linux build doesn't set `LM_FLAG_TRY` on journal lock requests during mount** (flags=0x284).

### Priority 4 — Script determinism

- [ ] setup-compute.sh: ensure idempotent re-runs on partially configured nodes
- [ ] deploy-kernel.sh: fix log line escaping (`$ip is up: $KVER` prints literally)

### Priority 5 — Documentation

- [ ] Update `docs/bast-mechanism.md` — entire doc describes removed yield mechanism
- [ ] Update `docs/summary.md` — claims cross-node I/O is blocked
- [ ] Update `docs/architecture.md` — BAST flow describes removed yield approach
- [ ] Update `docs/proposal.md` — status section says handoff under investigation

### Priority 6 — Performance optimizations (future)

These are design-level optimizations that borrow from DLM's architecture to reduce etcd latency pressure. Not yet planned for implementation.

- [ ] **Replace polling with etcd Watch in retryProcessLock.** Currently polls `ProcessLock` every 200ms (5 etcd round-trips/sec per waiting lock even when nothing changes). DLM uses event-driven callbacks. The retry goroutine should `Watch` the lock key instead and only call `ProcessLock` when the key changes (holder released). Cuts etcd traffic from O(ops/sec) to O(state changes).

- [ ] **Lock locality / in-kernel fast-path for reacquired locks.** When a node reacquires a lock it already holds (heartbeat, directory inode for a second file in the same directory), grant immediately in the kernel without the netlink→etcd round-trip. The kernel knows which locks it holds via `letcd_bast_insert`. Only when a different node wants the lock (BAST arrives) would the lock touch etcd. This would make the common case of repeated local access as fast as DLM. Requires: new `lm_lock` fast-path for `gl_state` already at or above the requested mode, and a "local grant" that skips the agent entirely.

## Additional docs

- `docs/epoch-mechanism.md` — cluster epoch for fencing rejection
- `docs/plan/etcd-compute-colocation.md` — etcd colocation design
- `docs/bast-mechanism.md` — BAST flow, livelock, yield solution
- `docs/glocks.md` — GFS2 glock state machine, lock types, modes
