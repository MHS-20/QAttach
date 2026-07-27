# QAttach — etcd-backed Distributed Lock Manager for GFS2

**STATUS: ABANDONED — NOT USABLE**

This project attempted to replace DLM (the kernel-level Distributed Lock
Manager) with etcd for GFS2 cluster filesystem coordination. After extensive
analysis and development, the approach was found to be architecturally
incompatible. This document describes the system, what was built, why it
fails, and what we learned.

---

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
- Translate GFS2 glock requests into netlink messages
- Track agent PID for unicast replies
- Maintain pending request table (request ID → glock awaiting completion)
- Maintain BAST lookup table (glock identity → glock for callbacks)
- Store fencing tokens (etcd revisions) in glock private data
- Validate fencing tokens on every grant

### cluster-agent (Go daemon)

One per compute node. Bridge between the kernel and etcd.

- Maintain an etcd session lease (TTL 15s, keepalive 5s)
- Handle netlink messages from the kernel (mount, lock, unlock, unmount)
- Translate lock requests into etcd CAS transactions via ProcessLock
- Watch for BAST requests on held locks and relay to the kernel
- FIFO lock handoff (HandoffRelease → /next marker → retryProcessLock)
- Assign journal IDs via etcd CAS on mount
- Monitor member keys for fencing detection
- Handle ASG lifecycle hooks for graceful termination

### etcd (3-node Raft cluster)

Source of truth for all distributed state.

Key categories:

- `/cluster/members/{id}` — node membership
- `/cluster/fencing/{id}` — CAS keys for fencing
- `/cluster/epoch` — monotonically increasing epoch counter
- `/cluster/journals/{jid}` — journal slot assignment
- `/locks/glock/{type}/{number}` — lock holders
- `/locks/glock/{type}/{number}/next` — FIFO handoff reservation
- `/locks/bast/{type}/{number}` — BAST request signal (waiter→holder)

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
  → SendBast(target=UNLOCK) to kernel
  → gfs2_glock_cb(gl, UNLOCKED)
  → do_xmote → lm_lock(UNLOCK)
  → LOCK_REL via netlink
  → agent: HandleLockRelease → HandoffRelease
  → atomically: delete lock key + write /next for oldest waiter

Node B: retryProcessLock sees delete event
  → ProcessLock: key empty, /next = Node B → acquire
  → send GRANT to kernel
  → trackHeldLock → spawn new watcher
```

### Release

```
GFS2: gfs2_glock_dq
  → lm_lock(UNLOCK)
  → letcd_lock(UNLOCK)
  → LOCK_REL via netlink
  → agent: HandleLockRelease → HandoffRelease
  → delete key + write /next for oldest waiter
```

### BAST (Blocking AST)

```
Waiter agent writes /locks/bast/{type}/{number}
Holder agent's watchBastAndYield goroutine fires
  → sends BAST(UNLOCK) to kernel
  → gfs2_glock_cb(gl, UNLOCKED)
  → kernel demotes or releases
  → agent sends HandoffRelease
  → waiter acquires via /next
```

## What works (mostly)

### Verified

- Single-node I/O on shared EBS volume across 3 nodes
- Multi-node mount (all 3 nodes mount GFS2)
- Cross-node reads of pre-existing files (8/8, 9/9 sequential tests)
- Cross-node overwrite of pre-existing files (node writes, others see edit)
- Cross-node append (node appends, others see appended data)
- Cross-node file creation in existing directories (node creates, others see it)
- Heartbeat lock handoff across 3 nodes (type=2 num=50063, 30s cycle)
- Agent-side lock protocol (ProcessLock, etcd Watch, retry)
- BAST → HandoffRelease → FIFO /next chain
- Kernel WAIT timeout (30s, prevents permanent D-state)
- Kernel cache invalidation (truncate_inode_pages on grant)

### Infrastructure

- Kernel build pipeline (launch.sh, dracut, depmod, gfs2-utils)
- Infrastructure provisioning (create/destroy via AWS API)
- Agent build and deployment (setup-compute.sh)
- Multiple instance types tested (m7i.large, m8i.4xlarge)
- Three-node infra repeatedly tested

## What doesn't work — and why

### Cross-node directory deletion (tested at depth)

When Node A deletes a file that was created by Node B, other nodes can't
verify the deletion. The process enters D-state permanently.

**Root cause**: GFS2's `find_first_holder()` returns a persistent inode cache
holder on the directory glock. The BAST signal arrives but `do_xmote` skips
the demotion because `find_first_holder` returns non-NULL. The lock never
releases. The waiter is stuck forever.

### Cross-node concurrent I/O (any rate > ~1 op/5s per node)

When two or more nodes write to the same file simultaneously, EX contention
creates D-state processes that may never resolve.

**Root cause**: Same `find_first_holder` problem for active file holders.
DLM works because the master node serializes access at microsecond latency.
etcd consensus takes ~5ms per operation, during which GFS2 processes block.

### Cross-node directory creation (intermittent)

When Node A creates a file and Node B reads it, the read may hang if
GFS2 on Node A caches the directory EX lock.

**Root cause**: GFS2 caches directory inode EX locks after file creation.
The cache duration is unpredictable (LRU-based). If another node requests
the lock during this window, the BAST→handoff cycle takes ~50ms — within
which the requesting process is already in D-state.

### 4th node addition (EBS attachment limits)

The EBS io2 Multi-Attach volume has concurrent attachment limits that
prevent reliable operation beyond 2-3 nodes on m7i.large instances.

**Root cause**: No software fix — hardware limit.

## What was attempted and why each fix was insufficient

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

## Why GFS2 + etcd is architecturally incompatible

### 1. Latency mismatch

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

### 2. No per-lock master

DLM assigns a master node for each lock. The master serializes all requests,
maintains a queue, and guarantees FIFO ordering. When a holder releases,
the master immediately grants to the next waiter — no race window.

lock_etcd is flat: each node's agent independently reads/writes etcd keys.
When a holder releases (HandoffRelease → delete key + write /next), there's
a window where the previous holder's GFS2 may re-request the lock before the
designated waiter can claim it. The /next FIFO marker prevents other nodes
from stealing, but the re-request from the original holder creates a tight
loop.

### 3. No lock conversion

DLM supports native lock mode conversion (EX→PR, PR→EX) in-place without
unlocking. This is how DLM handles BAST demotions — the holder converts
EX→PR instead of releasing and re-acquiring.

etcd has no concept of lock conversion. The only option is unlock→handoff→
reacquire, which creates a window where the lock is temporarily unowned.
GFS2 on the holder node may re-request during this window, creating
contention.

### 4. `find_first_holder` cannot be bypassed

This is GFS2's correctness guarantee: a glock cannot be demoted while a
process holds it. The holders are GFS2's reference count on the inode's
cached state. Without this check, GFS2 could have stale cache entries and
data loss.

DLM bypasses this by being fast enough that the holder releases before
`do_xmote` even checks `find_first_holder`. lock_etcd cannot match this
speed.

### 5. No callback-based wait

GFS2's `gfs2_glock_wait` is TASK_UNINTERRUPTIBLE — it blocks all signals.
The only exit is `gfs2_glock_complete`. If the lock manager doesn't call it
(etcd slow, agent crashed), the process stays D-state forever. There's no
timeout, no signal handler, no "try again later" path.

Our WAIT timeout (30s → LM_OUT_TRY_AGAIN) adds this escape, but it was a
hack on top of a design that lacks it natively.

## Key metrics from testing

- **8/8 cross-node sequential I/O** (pre-created files, 5s delay)
- **36/36 light concurrent test** (pre-created files, 5s interval, 3 files)
- **9/9 baseline I/O** (3-node setup, pre-created files)
- **0 permanent D-state** (with 30s WAIT timeout)
- **~5ms etcd round-trip** per lock operation
- **~65ms BAST→release→handoff→grant** cycle (measured)

## What the system actually demonstrates

Despite the fundamental incompatibility, the project built a working prototype
that demonstrates:

- A complete `lm_lockops` kernel module for GFS2 with Netlink communication
- A Go userspace agent with etcd session management, lock protocol, BAST
  handling, and FIFO handoff
- Integration with EBS io2 Multi-Attach and EC2 instance lifecycle
- AWS infrastructure provisioning scripts (create, deploy, destroy, test)
- Working IAM-based fencing code (requires IAM role to test)
- Kernel build pipeline with dracut, depmod, NVMe built-in

These components could be adapted for non-GFS2 use cases (distributed
application locking, lease management, active/passive volume coordination),
but not for GFS2 specifically.

## Repository structure

| Path | Purpose |
|------|---------|
| `cmd/cluster-agent/main.go` | CLI entrypoint |
| `internal/{etcd,fencing,identity,lifecycle,lock,membership,netlink,config,signal}/` | Go agent packages |
| `pkg/protocol/` | Shared Go/C types (glock modes, Netlink messages, etcd keys) |
| `kernel/` | `lock_etcd` kernel module (C, lm_lockops, built into gfs2.ko) |
| `scripts/infra/` | AWS infra, kernel deploy, compute setup, e2e tests |
| `scripts/kernel/` | Kernel build pipeline (launch.sh, patch-kernel.py) |
| `docs/` | Architecture, retrospectives, analysis |
