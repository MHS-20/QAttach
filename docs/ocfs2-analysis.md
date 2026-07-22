# OCFS2 Analysis — Would an etcd-backed lock manager work?

## Overview

OCFS2 (Oracle Cluster File System) is a shared-disk cluster filesystem that,
like GFS2, relies on a Distributed Lock Manager (DLM) for cache coherence.
The question is whether replacing the kernel DLM (`fs/dlm`) with an etcd-backed
lock manager (similar to lock_etcd) would encounter the same fundamental
limitations we found with GFS2.

## Architecture comparison

```
GFS2:  gfs2.ko (lm_lockops) ← Netlink → cluster-agent → etcd
OCFS2: ocfs2.ko (dlm_lock) ← kernel → fs/dlm (kernel DLM)
```

OCFS2's lock manager interface is called `dlm_lock` (not `lm_lock`).
It directly calls into the kernel's `fs/dlm` module, which provides
AST/BAST callbacks, lock queues, conversion, and deadlock detection.

OCFS2 has a "userspace stack" (`stack_user.c`) through `/dev/ocfs2_control`,
but this handles only membership and recovery — NOT actual locking. The
locking itself always goes through the kernel's `fs/dlm`.

This is fundamentally different from lock_etcd, where the lock state lives
in etcd and all decisions are made in userspace.

## The three critical issues

### 1. Holders block demotions (same as GFS2)

OCFS2 has the same pattern as GFS2's `find_first_holder`:

```c
// ocfs2_unblock_lock() — called when BAST arrives
if (lockres->l_blocking == DLM_LOCK_EX
    && (lockres->l_ex_holders || lockres->l_ro_holders))
        goto leave_requeue;  // defer — holders exist
```

When a BAST arrives (another node wants EX) and local holders exist, the
demotion is deferred — same as GFS2. The downconvert is queued for later.

**However**, OCFS2 has `ocfs2_downconvert_on_unlock()` which **proactively
wakes the downconvert thread** when the LAST holder drops. This prevents the
"stuck forever" scenario where nobody kicks the downconvert thread.

| | GFS2 | OCFS2 |
|---|------|-------|
| Holder blocking demotion | Yes (`find_first_holder`) | Yes (`l_ex_holders` / `l_ro_holders`) |
| Proactive wake on last holder drop | No | Yes (`ocfs2_downconvert_on_unlock`) |
| D-state prevention | WAIT timeout (30s → LM_OUT_TRY_AGAIN) | Signal-interruptible waits |

### 2. D-state vs signal-interruptible waits (OCFS2 is better)

OCFS2 uses `wait_event(lockres->l_event, ...)` and
`wait_for_completion(&mw->mw_complete)`. By default, signals ARE caught:

```c
// dlmglue.c, around line 1478
if (!(ocfs2_mount_local(osb) && !(flags & OCFS2_LOCK_NONBLOCK)))
    catch_signals = !OCFS2_MOUNT_NOINTR(osb);
```

When a signal arrives (e.g., from `timeout` or Ctrl+C), the lock wait returns
`-ERESTARTSYS`, which the VFS translates to `-EINTR` to userspace. The
process exits with an I/O error instead of hanging in D-state.

OCFS2 also has `OCFS2_LOCK_NONBLOCK` (0x04), which returns `-EAGAIN`
immediately if the lock can't be acquired — no sleeping at all.

GFS2 has **none** of these. `gfs2_glock_wait` enters TASK_UNINTERRUPTIBLE
and ignores all signals. The only exit path is `gfs2_glock_complete`. If the
lock manager never calls it, the process stays D-state forever.

| | GFS2 | OCFS2 |
|---|------|-------|
| Default wait state | D-state (uninterruptible) | Interruptible (signal-aware) |
| Killable with signals | No | Yes (returns -ERESTARTSYS) |
| Non-blocking flag | LM_FLAG_TRY (separate path) | OCFS2_LOCK_NONBLOCK (integrated) |

### 3. Lock conversion (the dealbreaker for etcd)

OCFS2 uses DLM's native lock conversion extensively:

```c
// __ocfs2_cluster_lock
lockres->l_action = OCFS2_AST_CONVERT;
lkm_flags |= DLM_LKF_CONVERT;
```

Every PR→EX upgrade and EX→PR demotion is a **convert**, not unlock+lock.
The DLM handles conversions with proper ordering, deadlock detection, and
queue management.

**etcd cannot do this.** A KV store has no concept of in-place mode
conversion, no lock queue, no deadlock detection. The only option is
unlock→handoff→reacquire — the same approach that causes the race windows
and livelock in lock_etcd.

If an etcd-backed lock manager for OCFS2 used unlock→reacquire for every
conversion, it would face the same handoff race problems as lock_etcd,
EVERY TIME a process upgrades from PR to EX (which happens on every
write-to-open-file).

## Would OCFS2 be easier than GFS2?

| Factor | OCFS2 vs GFS2 | Verdict |
|--------|---------------|---------|
| Holder blocking demotion | Same problem | **Same** |
| Lock conversion needed | Yes — heavily used | **Same** |
| D-state risk | Lower — signal-interruptible | **Better** |
| Non-blocking lock | Integrated flag | **Better** |
| Lock modes | Different values, 6 vs 4 | **Needs translation** |
| Userspace stack exists | Yes, for membership only | **Misleading — doesn't help** |

**Verdict: OCFS2 would encounter the same fundamental problems as GFS2.**

The lock conversion requirement is the killer. OCFS2 uses DLM's convert
feature in every lock operation — every file open requires a lock, and every
write requires a PR→EX conversion. Replacing this with unlock→handoff→
reacquire would introduce the same race window, handoff ordering, and
livelock issues in every write path, not just directory operations.

The signal-interruptible waits and non-blocking flags would make OCFS2 more
tolerant of the latency, converting permanent D-state into transient I/O
errors. But "more tolerant" is not the same as "works correctly."

## Conclusion

OCFS2 shares the same architectural dependency on kernel DLM semantics as
GFS2. The lock conversion requirement makes it as unsuitable for etcd-backed
locking as GFS2. The only improvement would be better failure modes
(signals can abort waiting processes), but the fundamental contention
problems from unlock→reacquire remain.

Neither GFS2 nor OCFS2 can have their lock manager replaced with a
high-latency, flat-consensus KV store without sacrificing correctness
or reliability.
