# QAttach — etcd-backed Distributed Lock Manager for GFS2

**STATUS: RESEARCH PROTOTYPE — NOT PRODUCTION-READY**

This project replaces DLM (the kernel-level Distributed Lock Manager) with etcd
for GFS2 cluster filesystem coordination. It was first declared architecturally
incompatible and abandoned. A later review against the GFS2 and DLM sources, and
then testing on a local three-node cluster, showed that most of the reported
failures were defects in this repository, not limits of etcd. The fixed system
passes concurrent metadata stress and node-crash recovery tests. Two genuine
incompatibilities remain; see [Remaining incompatibilities](#remaining-incompatibilities).

## What it is

QAttach replaces the standard DLM stack (Corosync + Pacemaker + `lock_dlm`)
that GFS2 normally requires with an etcd-backed locking protocol. A custom
kernel module (`lock_etcd`, built into `gfs2.ko`) implements GFS2's
`lm_lockops` interface and communicates with a userspace Go daemon
(`cluster-agent`) over Netlink family 31. The daemon uses etcd v3 as the
single source of truth for lock state, membership, and fencing coordination.
etcd is colocated on each compute node.

## Architecture

```
┌─────────────────────────────────────────────────────────┐
│                    Compute Node                          │
│                                                          │
│  ┌──────────┐   Netlink   ┌──────────────┐  gRPC        │
│  │ lock_etcd │◄──────────►│ cluster-agent│◄───────┐     │
│  │ (kernel)  │  family 31 │   (Go)       │        │     │
│  └────┬──────┘            └──────┬───────┘   ┌───┴───┐ │
│       │ lm_lockops               │            │ etcd  │ │
│  ┌────┴──────┐                   │            │(Raft) │ │
│  │   GFS2    │                   │            └───────┘ │
│  └────┬──────┘                   │◄──peer────────────── │
│       │                          │                      │
│  ┌────┴──────┐                   │                      │
│  │ EBS io2  │                   │                      │
│  │ MultiAtt.│                   │                      │
│  └──────────┘                   │                      │
└──────────────────────────────────┼──────────────────────┘
                                   │
                         ┌─────────┴─────────┐
                         │  Compute Node 2   │
                         │  (identical)      │
                         └───────────────────┘
```

### lock_etcd (kernel module)

A Linux kernel module implementing the `lm_lockops` interface that GFS2 uses
to interact with a lock manager. Built into `gfs2.ko` (not a separate module).

Responsibilities:

- Register custom AF_NETLINK family (31) for agent communication
- Translate GFS2 glock requests into netlink messages, passing the TRY,
  TRY_1CB and NOEXP flags through to the agent
- Track agent PID for unicast replies
- Maintain pending request table (request ID → glock awaiting completion)
- Maintain BAST lookup table (glock identity → glock for callbacks)
- Carry lock value blocks (LVBs) out on EX unlock or down-conversion, and in
  on every grant
- Map agent replies to GFS2's `LM_OUT_*` results, including deadlock,
  cancel and try-again
- Forward `lm_cancel` to the agent
- Replay a failed node's journal on request and report the result

### cluster-agent (Go daemon)

One per compute node. Bridge between the kernel and etcd.

- Maintain an etcd session lease (TTL 15s, keepalive 5s) for membership
- Handle netlink messages from the kernel (mount, lock, unlock, cancel,
  unmount, recovery result)
- Translate lock requests into etcd CAS transactions via ProcessLock
- Watch for BAST requests on held locks and relay them to the kernel
- FIFO lock handoff (ReleaseLock → `/next` reservation → retryProcessLock)
- Detect conversion deadlocks and fail the later converter, as DLM does
- Assign journal slots via etcd CAS on mount, and free them on unmount
- Fence failed nodes and drive the replay of their journals
- Handle ASG lifecycle hooks for graceful termination

### etcd (3-node Raft cluster)

Source of truth for all distributed state. See `docs/etcd-schema.md`.

Key categories:

- `/cluster/members/{id}` — node membership (session lease)
- `/cluster/fencing/{id}` — CAS keys that pick the node fencing a failed peer
- `/cluster/epoch` — monotonically increasing epoch counter
- `/cluster/journals/{jid}` — journal slot assignment (persistent)
- `/cluster/recovery/{jid}` — recovery barrier while a journal awaits replay
- `/locks/glock/{type}/{number}` — lock holders (persistent)
- `/locks/glock/{type}/{number}/next` — FIFO handoff reservation
- `/locks/bast/{type}/{number}` — BAST request signal (waiter→holder)
- `/locks/lvb/{type}/{number}` — lock value block

## Lock flow

### Acquire (contended)

```
Node B: lm_lock(SH)
  → letcd_lock(SH)
  → LOCK_REQ via netlink
  → agent: ProcessLock
  → etcd shows Node A holds EX → conflict
  → write BAST key + waiter entry
  → send WAIT to kernel
  → start retryProcessLock goroutine (watches lock key)

Node A: watchBastAndYield fires
  → SendBast(target=SH, since the waiter wants SH) to kernel
  → gfs2_glock_cb(gl, SHARED)
  → do_xmote → lm_lock(SH): EX → SH down-conversion
  → LOCK_REQ carrying the LVB via netlink
  → agent: publish LVB, then ProcessLock updates Node A's entry to PR
    (an EX waiter would force UNLOCK instead: LOCK_REL → ReleaseLock →
    atomically delete lock key + write /next for the oldest waiter)

Node B: retryProcessLock sees the lock key change
  → ProcessLock: no conflicting holder (or /next = Node B) → acquire
  → send GRANT with the current LVB to kernel
  → trackHeldLock → spawn new watcher
```

### Release

```
GFS2: gfs2_glock_dq
  → lm_lock(UNLOCK)
  → letcd_lock(UNLOCK)
  → LOCK_REL (with the LVB if the lock was EX) via netlink
  → agent: HandleLockRelease → publish LVB → ReleaseLock
  → remove this node's entry; if none remain, delete the key and write
    /next for the oldest waiter in the same Txn
```

### BAST (Blocking AST)

```
Waiter agent writes /locks/bast/{type}/{number}
Holder agent's watchBastAndYield goroutine fires
  → waits out minHoldTime (200ms, like GFS2's gl_hold_time)
  → sends BAST(target mode) to kernel
  → gfs2_glock_cb(gl, target)
  → kernel demotes or releases once its holders are done
  → waiter's retryProcessLock acquires
```

## Current results

These results come from the local test cluster (see [Testing locally](#testing-locally)):
three QEMU/KVM guests running kernel 6.18.54 with lock_etcd, sharing one raw
disk image, against a single etcd. They have not been repeated on AWS.

| Test | Result |
|------|--------|
| 3-node mount, unmount, remount | Works |
| Sequential cross-node create, read, append, delete | Works |
| 3 nodes × 500 random append/unlink/read/readdir ops on one shared directory | 0 I/O errors, 0 timeouts, ~95s; `fsck.gfs2 -n` clean in most runs |
| `flock` across nodes, blocking and `-n` | Mutual exclusion and non-blocking semantics correct |
| Crash of one node mid-write (VM killed) | Survivors resume after ~15s; the victim's journal is replayed; synced data survives; no withdraw |
| Crash of all three nodes, then remount | Each node replays its own journal at mount; synced data survives; `fsck.gfs2 -n` clean |
| POSIX `fcntl` locks | Fail with `ENODEV` — see below |

After a crash, or occasionally after a crash-free stress run, `fsck.gfs2 -n`
can report one dinode still marked *unlinked* and a stale statfs summary. An
unlinked dinode is a file that was deleted while still open; GFS2 reclaims it
when it next allocates from that resource group. This run did not compare the
rate against a DLM cluster.

Throughput was not benchmarked against DLM. Every contended lock transition
costs at least one etcd round trip.

## What was wrong

The original analysis (see `docs/retrospective.md`) blamed GFS2's design and
etcd's latency. The failures came from lock-manager semantics that lock_etcd
did not implement:

| Defect | Symptom | Fix |
|--------|---------|-----|
| No conversion-deadlock handling. Nodes holding SH that all request EX wait on each other, because GFS2 cannot demote a glock whose own conversion is in flight. | 20s stall, then EIO, on every contended directory | The agent detects the cycle in etcd (a conflicting holder is itself a waiter) and denies the later converter with `LM_OUT_DEADLOCK`. GFS2 then unlocks and retries, as it does for DLM's `-EDEADLK`. |
| Lock value blocks never propagated. GFS2 enables `rgrplvb` by default for on-disk format 1802, so a node trusted its own stale copy of a resource group's counts. | `fatal: filesystem consistency error` in `gfs2_rgrp_go_instantiate`, and the filesystem withdrew | LVBs travel with unlock, down-conversion and grant, and are stored in etcd. An LVB that was not handed over is zeroed, like `DLM_SBF_VALNOTVALID`. |
| `lm_cancel` was a no-op. GFS2 cancels an iopen upgrade after 5s and sleeps until the request completes. | EIO when deleting files other nodes had cached | The kernel forwards the cancel; the agent ends the wait with `LM_OUT_CANCELED`. |
| TRY requests were refused locally without asking etcd | `flock -n` never saw the other node's lock; remote-delete "pokes" never happened, leaving unlinked inodes allocated | The agent decides TRY against etcd without queueing (DLM's `NOQUEUE`), and sends one BAST for TRY_1CB (`NOQUEUEBAST`). |
| Lock keys on the session lease | A crashed node's locks were released at lease expiry, before fencing or journal replay. A survivor read metadata that existed only in the dead node's journal and withdrew. | Lock keys and journal slots are persistent; recovery purges them after fencing, behind a barrier (see below). |
| Journal slot never released on unmount | Remount failed with "Too many users" | Freed on unmount. |

## Crash recovery

The sequence mirrors what DLM and `lock_dlm` do:

1. A node dies; its session lease expires and its member key disappears. Its
   lock entries stay in etcd, so requests that conflict with them keep waiting.
2. Every mounted agent periodically looks for journal slots whose owner is not a
   live member. One wins a CAS on `cluster/fencing/{node}` and fences the node
   (`--fence-mode=ec2`: stop the instance, falling back to a forced EBS detach).
3. The winner raises the barrier `cluster/recovery/{jid}`. From then on only
   requests carrying GFS2's `LM_FLAG_NOEXP` are granted anywhere.
4. It purges the dead node's lock entries, and drops the LVBs of locks that
   node held EX.
5. It asks its kernel to replay the journal (`RECOVERY_OK`). GFS2 takes the
   journal lock with NOEXP and replays it.
6. On `LM_RD_SUCCESS` the barrier and the journal slot are removed in one
   transaction, and the cluster epoch is incremented.

A node that crashes and remounts under the same node ID adopts its old journal
slot. It purges its own stale lock entries before this mount takes any lock,
and raises a barrier that exempts only itself; GFS2 replays the journal during
the mount, which lowers it. A whole-cluster restart recovers this way.

The scan is level-triggered: if the recovering node dies too, its fencing claim
expires and the next scan repeats the work. Every step is idempotent.

**Limitation.** A live node that has not remounted keeps its old journal slot
and lock entries until it does. Requests that conflict with those entries wait
until then.

## Remaining incompatibilities

1. **POSIX locks.** GFS2 does not route `fcntl` byte-range locks through
   `lm_lockops`. `gfs2_lock` in `fs/gfs2/file.c` calls `dlm_posix_lock()` on the
   DLM lockspace `ls->ls_dlm`, which only `lock_dlm` creates, and returns
   `-ENODEV` without one. No lock module can provide cluster-wide POSIX locks
   without patching GFS2 or running DLM beside it. `flock` is unaffected: it
   uses glocks.
2. **Lease-based ownership.** Tying lock ownership to an etcd lease, the natural
   etcd idiom, is unsafe for a shared-disk filesystem: the lease releases a
   dead node's locks before its journal is replayed. Recovery needs lock state
   that outlives the node, plus a barrier and fencing — what DLM provides
   internally. QAttach now implements this; it is a design constraint, not a
   blocker.

Fencing remains mandatory, exactly as with DLM. `--fence-mode=none` exists
only for the local test harness, which kills nodes itself.

## Testing locally

`scripts/docker/` runs the whole stack on one machine with `/dev/kvm`: one
container with etcd, and three QEMU/KVM guests booting a 6.18 kernel with
lock_etcd built in and sharing a raw GFS2 image. No AWS resources are used.

```bash
scripts/docker/run.sh build        # image, kernel (first build ~10 min) and agent
scripts/docker/run.sh up           # fresh disk, etcd and 3 guests
scripts/docker/mount-all.sh
scripts/docker/stress.sh 500 20    # concurrent metadata churn on a shared directory
scripts/docker/crash.sh 1          # kill node1 mid-write, verify survivors and fsck
scripts/docker/node.sh 0 'ls /mnt/gfs2'   # run a command in a guest
scripts/docker/run.sh crash 2; scripts/docker/run.sh boot 2   # crash and reboot a guest
scripts/docker/run.sh down
```

Build output, kernel source, the disk image and per-node logs (`console.log`,
`dmesg.log`, `agent.log`) live in `~/.cache/qattach-docker`
(`QATTACH_DOCKER_WORK`).

## History

The sections below record the original July 2026 analysis. Its conclusions are
superseded by [Current results](#current-results), but it documents what was
tried.

### What was attempted and why each fix was insufficient

12 distinct approaches were tested over weeks:

| Approach | Outcome |
|----------|---------|
| BAST + atomic handoff | Livelock — holder reacquires faster than waiter |
| No BAST, just wait | Holder-reacquire race — holder always wins |
| Kernel ordered queue | Only orders within a node, not cross-node |
| Yield flag in kernel | Race with reacquire, superseded by BAST |
| Proactive BAST watch + persistent yield | Works for heartbeat, fails for directories |
| HASWAITER check in BAST watcher | Race window between check and watch setup |
| WatchFrom revision in retryProcessLock | Correct race fix, doesn't fix contention |
| INODE 5s timeout + DENY (instead of WAIT) | Converts deadlock to I/O error — usable but fragile |
| Centralized BAST dispatcher | Broke basic reads, unknown cause |
| Cache invalidation (truncate_inode_pages) | Works for file creation, requires GRANT to arrive |
| DLM_SBF_DEMOTED flag | Doesn't exist in GFS2 for our kernel |
| GLF_INVALIDATE flag | Not present in kernel 6.18 |

The only approach that provides a usable outcome (5s INODE timeout + DENY)
converts permanent D-state into transient I/O errors — the process gets
EIO and must retry. This is insufficient for a production shared filesystem.

### The original incompatibility argument (superseded)

Each point below is refuted in `docs/retrospective.md`.

#### 1. Latency mismatch

| Metric | DLM | lock_etcd |
|--------|-----|-----------|
| Local lock acquisition | ~1µs | ~5ms |
| Remote lock acquisition | ~10µs | ~5ms + agent processing |
| BAST→release cycle | ~100µs | ~5-15ms |
| Lock conversion (EX→SH) | Native | Not supported |

GFS2's glock state machine expects lock manager responses at microsecond
timescales. etcd operates at millisecond timescales. When a lock takes
longer than GFS2 expects, the process enters D-state (uninterruptible sleep)
and stays there until the lock is granted.

#### 2. No per-lock master

DLM assigns a master node for each lock. The master serializes all requests,
maintains a queue, and guarantees FIFO ordering. When a holder releases,
the master immediately grants to the next waiter — no race window.

lock_etcd is flat: each node's agent independently reads/writes etcd keys.
When a holder releases (HandoffRelease → delete key + write /next), there's
a window where the previous holder's GFS2 may re-request the lock before the
designated waiter can claim it. The /next FIFO marker prevents other nodes
from stealing, but the re-request from the original holder creates a tight
loop.

#### 3. No lock conversion

DLM supports native lock mode conversion (EX→PR, PR→EX) in-place without
unlocking. This is how DLM handles BAST demotions — the holder converts
EX→PR instead of releasing and re-acquiring.

etcd has no concept of lock conversion. The only option is unlock→handoff→
reacquire, which creates a window where the lock is temporarily unowned.
GFS2 on the holder node may re-request during this window, creating
contention.

#### 4. `find_first_holder` cannot be bypassed

This is GFS2's correctness guarantee: a glock cannot be demoted while a
process holds it. The holders are GFS2's reference count on the inode's
cached state. Without this check, GFS2 could have stale cache entries and
data loss.

DLM bypasses this by being fast enough that the holder releases before
`do_xmote` even checks `find_first_holder`. lock_etcd cannot match this
speed.

#### 5. No callback-based wait

GFS2's `gfs2_glock_wait` is TASK_UNINTERRUPTIBLE — it blocks all signals.
The only exit is `gfs2_glock_complete`. If the lock manager doesn't call it
(etcd slow, agent crashed), the process stays D-state forever. There's no
timeout, no signal handler, no "try again later" path.

Our WAIT timeout (30s → LM_OUT_TRY_AGAIN) adds this escape, but it was a
hack on top of a design that lacks it natively.

### Key metrics from the July testing

- **8/8 cross-node sequential I/O** (pre-created files, 5s delay)
- **36/36 light concurrent test** (pre-created files, 5s interval, 3 files)
- **9/9 baseline I/O** (3-node setup, pre-created files)
- **0 permanent D-state** (with 30s WAIT timeout)
- **~5ms etcd round-trip** per lock operation
- **~65ms BAST→release→handoff→grant** cycle (measured)

## Repository structure

| Path | Purpose |
|------|---------|
| `cmd/cluster-agent/main.go` | CLI entrypoint |
| `internal/{etcd,fencing,identity,lifecycle,lock,membership,netlink,config,signal}/` | Go agent packages |
| `pkg/protocol/` | Shared Go/C types (glock modes, Netlink messages, etcd keys) |
| `kernel/` | `lock_etcd` kernel module (C, lm_lockops, built into gfs2.ko) |
| `scripts/infra/` | AWS infra, kernel deploy, compute setup, e2e tests |
| `scripts/kernel/` | Kernel build pipeline (launch.sh, patch-kernel.py) |
| `scripts/docker/` | Local QEMU/KVM test cluster, stress and crash tests |
| `docs/` | Architecture, retrospectives, analysis |
