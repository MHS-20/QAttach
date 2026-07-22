# QAttach Retrospective — Why GFS2 on etcd locking is not viable

## The premise

QAttach replaces DLM (a kernel-level distributed lock manager) with etcd, a
user-space consensus KV store. GFS2, a shared-disk cluster filesystem, uses the
lock manager (`lm_lockops`) to coordinate access to inodes across nodes. The
idea was that etcd's CAS transactions and leases could replicate the locking
behavior of DLM, eliminating the need for the full Corosync/Pacemaker stack.

After weeks of development and testing, the conclusion is:

**GFS2 and etcd are architecturally incompatible for directory metadata
operations. The system works for basic file I/O under conditions, but the
failure modes are inherent and unfixable from the lock manager layer.**

## What works

- Single-node I/O on a shared EBS volume
- Multi-node mount (with carefully sequenced agent startup)
- Heartbeat lock cycling via BAST→HandoffRelease (type=2 n=50063)
- Cross-node read/write/append of pre-existing files without directory metadata changes
- Agent-side locking protocol: ProcessLock, retryProcessLock, etcd Watch, FIFO handoff

## What doesn't work

- Cross-node file creation (directory EX contention → permanent D-state)
- Cross-node file deletion (same root cause)
- Cross-node `ls`, `stat`, or any metadata read after a directory mutation on another node
- Concurrent I/O at any rate exceeding ~1 op/5s per node (intermittent D-state)

## Root cause: GFS2's `find_first_holder` deadlock

When Node B wants to modify a directory (create/delete a file), it requests EX
on the directory inode. Node A holds the directory lock (PR or EX, cached by
GFS2). The agent sees contention and sends a BAST to Node A.

The BAST arrives via netlink → `gfs2_glock_cb` → sets `GLF_DEMOTE` flag.
GFS2's glock work function (`do_xmote`) runs and calls `find_first_holder(gl)`.
If any process on Node A holds the glock (even a completed `ls` whose cached
data hasn't been evicted), `find_first_holder` returns non-NULL.
`do_xmote` returns WITHOUT calling `lm_lock`. The BAST is effectively ignored.
The lock stays EX (or PR) on Node A forever.

Node B's process enters `gfs2_glock_wait` → D-state (uninterruptible sleep,
no signals processed). The agent's retry goroutine watches etcd but the lock
never changes → 120s timeout → DENY → GFS2 retries → cycle repeats.

**This is not a bug in our code. It is GFS2's intended behavior.** The
`find_first_holder` check exists precisely to prevent demoting a glock while
a process is using it — this would break GFS2's cache coherence guarantees.
DLM bypasses this not by circumventing `find_first_holder`, but by ensuring
the holder process finishes its I/O before the demotion is needed.

## Why DLM works

DLM is a **kernel-level, per-lock master** architecture:

1. Each lock has a designated "master" node
2. The master serializes all requests for that lock
3. When Node B requests EX on a directory, the DLM master queues it
4. DLM sends BAST to the holder (Node A)
5. The holder's `gdlm_bast` calls `gfs2_glock_cb`, setting GLF_DEMOTE
6. GFS2's `do_xmote` runs, checks `find_first_holder` — if blocked, defers
7. When the holder's process naturally finishes and releases the holder,
   `find_first_holder` returns NULL → `do_xmote` proceeds → `lm_lock` called
8. DLM master grants the lock to Node B (the next in queue)

Key: **DLM knows a waiter exists and will grant to it first.** The holder process
finishes naturally and the lock goes directly to the waiter — no race, no window.

## Why etcd can't replicate this

etcd is a **flat, consensus-based KV store** — no per-lock master:

1. Every lock acquisition goes through a CAS transaction (`/locks/glock/{t}/{n}`)
2. Decision-making is distributed — each node's agent independently checks holders
3. There is no global queue — only a `/next` handoff marker
4. Between the holder's BAST→release→DELETE and the waiter's CREATE, **any
   node can claim the lock**, including the previous holder whose GFS2 glock
   work re-requested it

The `/next` FIFO marker prevents non-designated nodes from claiming when the
lock key is empty. But GFS2 on the previous holder may re-request the lock
**before** the designated waiter's watch fires. If the re-request arrives
while the key is empty (the race window after HandoffRelease deletes the key
and before the waiter processes the event), the previous holder's agent calls
ProcessLock, sees the key is empty AND `/next` names the waiter → refuses it.
But GFS2 immediately sends another LOCK_REQ, and another, and another —
creating a tight loop that keeps the etcd key bouncing between "empty but
blocked by /next" and "claimed by waiter" faster than the waiter can respond.

## The latency gap

| Metric | DLM | lock_etcd |
|--------|-----|-----------|
| Lock acquisition (local) | ~1µs | ~5ms (etcd consensus) |
| Lock acquisition (remote) | ~10µs | ~5ms + agent processing |
| BAST→release cycle | ~100µs | ~5ms (etcd write + watch) |
| Cache invalidation | Built into DLM protocol | No mechanism in lm_lockops |

DLM operates at microsecond scale within the kernel. lock_etcd operates at
millisecond scale across userspace ↔ kernel ↔ etcd network. GFS2 expects the
lock manager to resolve contention within the time it takes a process to
complete a filesystem operation (~10µs–1ms). Our latency is 5-50x higher.

When a GFS2 process takes longer than expected to acquire a lock (because
the lock manager is slow), the process enters `gfs2_glock_wait` (D-state).
This is GFS2's only mechanism for waiting — it does not have a "non-blocking
lock attempt with callback" path. Once in D-state, the process is stuck until
the lock manager grants the lock. If the lock manager can't deliver within
`do_xmote`'s tolerance (which is essentially immediate), the process stays
stuck forever.

## Every fix attempted and why each is insufficient

| Approach | What went wrong |
|----------|-----------------|
| BAST + atomic handoff | Livelock — holder reacquires faster than waiter can claim |
| No BAST, just wait | Holder-reacquire race — holder wins every time |
| Kernel ordered queue | Only orders within a node, not between nodes |
| Yield flag in kernel | Holdover from old approach — race with reacquire |
| Proactive BAST watch + persistent yield | Works for heartbeat, fails for directories |
| HASWAITER check | Race window between check and watch setup |
| WatchFrom revision fix | Correct race fix but doesn't solve contention |
| BAST → HandoffRelease → /next FIFO | Works for heartbeat lock but directory locks re-request too fast |
| INODE 5s timeouts + DENY | Converts deadlock into I/O error — functional but not transparent |
| Centralized BAST dispatcher | Broke basic reads for unknown reasons |
| Cache invalidation (truncate_inode_pages) | Works for file creation but requires GRANT to arrive — doesn't fix the deadlock |
| DLM_SBF_DEMOTED / GLF_INVALIDATE flags | Flags don't exist or are checked only by DLM's own callbacks, not GFS2 core |

Of 12 approaches, only one (5s INODE timeout + DENY) produces a viable but
limited result: cross-node directory operations get I/O errors instead of
permanent deadlock. Applications must retry. This is not production-grade for
a shared filesystem.

## Why this cannot be fixed

The fundamental architectural barriers:

1. **GFS2 expects microsecond lock resolution.** The `find_first_holder`
   check is not a bug — it's a correctness guarantee. GFS2 cannot allow a
   glock to be demoted while a process holds it, because that would break
   the journal ordering and cache coherence. DLM meets the microsecond
   timing requirement naturally. etcd cannot.

2. **lm_lockops has no async completion path for lock conflicts.**
   `lm_lock` is a synchronous call: it either grants immediately (return 0)
   or defers (return 0, DLM will call the AST later). But there is no
   callback mechanism to tell GFS2 "you can't get this lock, go do something
   else." The only way to release a blocked process is to complete its glock
   via `gfs2_glock_complete` — which means granting the lock (either the
   requested mode or an error). There is no "try again later" without the
   process sleeping in D-state.

3. **etcd consensus has inescapable latency.** Each lock operation requires
   at least one etcd round-trip (Get + Txn). In a 3-node Raft cluster,
   this is ~5ms minimum. GFS2's glock work runs every time a process accesses
   an inode — multiple times per filesystem operation. The aggregate latency
   makes any high-throughput workload infeasible.

4. **No distributed lock queue.** DLM's primary advantage is the per-lock
   master that knows the full request queue. lock_etcd has no way to know
   who is waiting for which lock — the waiter list is in etcd, and reading it
   requires another round-trip, which adds latency to every contention
   resolution.

5. **Cache invalidation requires DLM-level protocol context.** When a lock
   is granted after being held by another node, GFS2 needs to know "the data
   changed" — this is conveyed through DLM's `DLM_SBF_DEMOTED` flag, which is
   set by DLM's own callback chain (`gdlm_bast` → `gdlm_ast`). lock_etcd's
   dispatch path bypasses DLM entirely, so even if we set this flag,
   nothing checks it. The only invalidation mechanism that worked
   (`truncate_inode_pages`) is a hack that duplicates what DLM does
   natively.

## What we built

Despite the fundamental incompatibility, the system demonstrates:

- A working agent-side locking protocol (ProcessLock, BAST, FIFO handoff,
  etcd Watch)
- A kernel-side `lm_lockops` implementation that correctly translates
  GFS2 lock states to etcd operations
- Functional kernel module integration (netlink family 31, module build
  pipeline, dracut integration)
- Working IAM-based fencing code (requires IAM role attachment to test)
- Infrastructure scripts (EC2 auto-scaling, kernel deploy, etcd bootstrap)
- AWAIT timeout safety net (prevents permanent D-state at 30s)

These components are reusable for other locking schemes (see section below).

## Verdict

GFS2 on lock_etcd is not production-viable. The architectural mismatch is
fundamental: GFS2 demands a lock manager that operates at kernel-microsecond
timescales with a per-lock master queue. etcd operates at network-millisecond
timescales with flat consensus. No amount of optimization at the agent or
kernel module level can bridge this gap.

The system works for basic I/O under ideal conditions (low contention,
pre-existing files, sequential operations with large delays). It fails
unpredictably under any directory mutation or concurrent access.

## Possible alternative directions

The etcd-backed lock manager components (agent protocol, kernel module,
infrastructure) could be adapted for:

1. **A simpler use case**: locking non-GFS2 resources where the semantics are
   simpler (e.g., a distributed lock server for application-level coordination)

2. **A different filesystem**: overlayfs or NFS-ganesha with etcd-backed
   coordination, where the filesystem doesn't have GFS2's glock state machine

3. **Block-level coordination**: etcd as a lease manager for EBS Multi-Attach
   volume ownership, where only one node writes at a time (active/passive)

4. **Pure stateless lock service**: the agent protocol as a standalone etcd
   lock library, without the kernel module or GFS2 dependency

None of these are QAttach. The original GFS2+etcd vision is not achievable.
