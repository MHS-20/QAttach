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

## Current state — what works, what doesn't, and why

### Works: Single-node mount

Node 0 mounts GFS2 reliably. Lock requests flow correctly:
1. Mount request → agent assigns jid → mount response
2. Superblock lock (type=1 num=0 EX) → agent grants EX → GFS2 proceeds
3. Journal lock (type=1 num=1 EX) → agent grants EX → GFS2 mounts
4. Heartbeat + filesystem I/O locks flow correctly

### Broken: Multi-node mount (ANY second node)

The mount hangs on the very first lock (superblock, type=1 num=0 EX). Both nodes compete for EX on the same superblock. Node 0 already holds EX. Node 1 requests EX. Agent sends WAIT. retryProcessLock polls forever.

### The core problem: lock_etcd cannot do mode conversion

**DLM's approach (working)**: When two nodes contend for an EX lock, DLM sends a **blocking AST** (BAST) to the holder with target mode SH. GFS2 processes this via `gfs2_glock_cb → request_demote → run_queue`. The holder's glock is **converted** from EX to SH — holders stay active through the conversion. The `state_change(gl, LM_ST_SHARED)` is called with `ret=3` (SH mode). No unlock, no release, no handoff. Both nodes end up holding SH.

**lock_etcd's approach (broken)**: When two nodes contend for an EX lock, the agent sends BAST to the holder. The kernel module receives BAST → `dispatch_bast` → `gfs2_glock_cb(gl, target_mode)` → GFS2 marks the glock for demotion. But `run_queue` → `find_first_holder(gl)` returns non-NULL because the glock has active holders. **Demotion is blocked.** The lock can't be converted EX→SH without a full unlock/reacquire cycle. But a full unlock requires all holders to release, which never happens for mount-held locks.

**The critical GFS2 code paths** (from reference source `/tmp/gfs2-src/linux/fs/gfs2/`):

`run_queue` (glock.c):
```c
if (test_bit(GLF_DEMOTE, &gl->gl_flags)) {
    if (find_first_holder(gl))
        return;   // holders block demotion — this always fires for our locks
    // ... proceed with do_xmote for demotion
}
```

`finish_xmote` (glock.c) — how ret values are handled:
```c
if (!(ret & ~LM_OUT_ST_MASK)) {        // true for ret=0,1,2,3
    state = ret & LM_OUT_ST_MASK;      // extract mode
    state_change(gl, state);           // transition gl_state
}
// ret >= 4 (LM_OUT_ERROR=0x04, TRY_AGAIN=0x20, etc.): error path
```

`gdlm_ast` (lock_dlm.c) — DLM's completion callback:
```c
ret = gl->gl_req;                      // requested LM_ST_* value (0-3)
gfs2_glock_complete(gl, ret);          // triggers finish_xmote → state_change
```

`gdlm_bast` (lock_dlm.c) — DLM's blocking AST callback:
```c
gfs2_glock_cb(gl, LM_ST_UNLOCKED);     // demote target (EX requester → UN)
// or
gfs2_glock_cb(gl, LM_ST_SHARED);       // demote target (SH requester → SH)
```

### Why multi-node mount worked before (v0.0.3 era)

Before the lock mode "fix" was reverted, the constants were `EX=1, SH=3` (correct mapping). But wait — that's the same as now. So why did v0.0.3 work?

The answer may be that v0.0.3 used a different agent lock flow (`ConvertLock` + `watchForLock` instead of `ProcessLock`). The old flow might have handled EX→EX differently. Or the old kernel module had different behavior. This needs investigation.

### What the current kernel module can and cannot do

**Can do**: Acquire new locks (UN→EX, UN→SH), release locks (EX→UN, SH→UN). Lock state machine is correct for single-node use.

**Cannot do**: Mode conversion (EX→SH) without a full unlock/reacquire cycle. The kernel module has no code path for `lm_lock(gl, LM_ST_SHARED)` when `gl_state == LM_ST_EXCLUSIVE`. The `letcd_lock` function treats any non-UNLOCK `req_state` as a fresh acquisition, not a conversion.

## Known bugs (blocking e2e)

### CRITICAL: Multi-node mount blocked — lock_etcd cannot do EX→SH mode conversion

**Root cause**: GFS2 acquires the superblock in EXCLUSIVE mode during `gfs2_fill_super`. When a second node mounts, it also requests EX on the superblock. DLM resolves this by sending a BAST that forces the first holder to **convert** EX→SH (not unlock). GFS2's `run_queue` handles this conversion via `do_xmote` with the demoted target. lock_etcd has no mode conversion support — it can only do unlock→handoff→reacquire, which is blocked by `find_first_holder()`.

**Same issue affects journal locks**: Node 0 holds its journal EX permanently. Node 1's journal recovery check tries to acquire EX on node 0's journal with `LM_FLAG_TRY`. DLM returns -EAGAIN synchronously when TRY can't be granted. Our kernel must do the same — but `LM_FLAG_TRY` is not set by GFS2 on this kernel version, and even if it were, returning -EAGAIN via `gfs2_glock_complete` causes GFS2 to abort the entire mount (not just skip the journal).

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

## Remaining todo

### Priority 1 — Mode conversion (kernel + agent)
- [ ] Kernel: add `lm_lock(gl, LM_ST_SHARED)` support when `gl_state == LM_ST_EXCLUSIVE` (conversion path, not new acquisition)
- [ ] Agent: handle mode conversion in etcd — update holder entry from EX→PR without full release
- [ ] Kernel: investigate why GFS2's Amazon Linux build doesn't set `LM_FLAG_TRY` on journal lock requests during mount (flags=0x284)
- [ ] Kernel: if TRY flag path needs to work, ensure `gfs2_glock_complete(gl, LM_OUT_TRY_AGAIN)` causes GFS2 to skip the journal, not abort mount

### Priority 2 — Kernel correctness (requires kernel rebuild)
- [ ] Move inline-SH fast-path outside yield-suppress block
- [ ] Add `letcd_ordered_cleanup()` for ordered list drain on unmount

### Priority 3 — Agent robustness (no kernel changes)
- [ ] Fix `isEndpointHealthy` client leak: each health check creates new `clientv3.New(DialTimeout:10s)` while ticker fires every 2s
- [ ] Fix `hasExistingData` restart: writes `initial-cluster` with all 3 members even for single-node clusters
- [ ] Remove debug `netlink recv/dispatch` log lines in `server.go`
- [ ] Revert unnecessary `nlh.Pid` and `nlh.Type` changes in `sendMsg` (or document properly)

### Priority 4 — Script determinism
- [ ] deploy-kernel.sh: verify custom kernel boots after reboot (check `uname -r`)
- [ ] setup-compute.sh: ensure idempotent re-runs on partially configured nodes (currently fails if aborted mid-way through node loop)

### Priority 5 — Documentation
- [ ] Update `docs/` to reflect current state

## Additional docs

- `docs/epoch-mechanism.md` — cluster epoch for fencing rejection
- `docs/plan/etcd-compute-colocation.md` — etcd colocation design
- `docs/bast-mechanism.md` — BAST flow, livelock, yield solution
- `docs/glocks.md` — GFS2 glock state machine, lock types, modes
