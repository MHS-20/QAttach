# Multi-node Lock Contention: Analysis & Solution History

## The Actual Problem

When two GFS2 nodes do concurrent I/O (e.g. creating files in the same
directory), they contend on the same inode glock.  The deadlock is NOT
the classic two-lock AB/BA pattern — it's a **single-lock holder-reacquire
race**:

```
Time  Node 0 (holder)                           Node 1 (waiter)
────  ──────────────────────────────────────    ──────────────────────────
  1   holds inode lock 33384 in SH mode
  2                                               wants EX on 33384
  3                                               CAS fails → LOCK_WAIT
  4                                               writes bast key (signal)
  5                                               watchAndRetry starts
  6   GFS2 glock cycle: releases 33384 (SH)
  7   GFS2: "I still need this" → self-contention
  8   self-contention: release → CAS → reacquire EX
  9                                               watch sees DELETE
 10                                               tries CAS → key exists
 11                                               🔁 contention loop
```

The holder releases every ~30s via GFS2's periodic glock work function,
then _immediately reacquires_ via self-contention in the same goroutine.
The waiter's watchAndRetry — which must travel etcd→kernel→goroutine —
can never win this race because the holder's reacquire happens in
microseconds with no network delay.

This is fundamentally different from the AB/BA deadlock (two nodes holding
complementary locks).  Both nodes are contending on the _same_ lock, not
two different locks.

## Why DLM Avoids This

DLM daemons on every node communicate via TCP and share the global lock
dependency graph.  When Node 0 holds a lock and Node 1 wants it, the DLM
arbitrates: it either tells the holder to demote (BAST) _and_ guarantees
the waiter gets priority.  Our agent only sees etcd keys (granted locks),
not pending requests, so it can't prioritise waiters naturally.

## Approach Timeline

### 1. BAST + Handoff + Compatibility Matrix

Node B's CAS fails → writes a bast key.  Holder watches it, sends BAST to
kernel.  Holder demotes, atomic handoff reserves lock for waiter.

**Result: livelock.**  EX holder receives BAST(SH), releases, but GFS2's
glock work function immediately reacquires EX because it still needs it.
Ping-pong forever between EX→release→EX on both nodes.

### 2. No BAST, Just Wait

No bast, no handoff.  Node B does LOCK_WAIT and watches for the lock key
to be deleted.  Holder releases naturally when GFS2 completes I/O.

**Result: deadlock.**  Initially thought to be AB/BA (both nodes hold
complementary locks), but later analysis shows it's the single-lock race —
the holder reacquires before the waiter can.

### 3. Kernel-level Ordered Queue

Kernel module (`letcd_ordered_drain`) serialises lock requests within a
node: lower `orderKey` locks must complete before higher ones.

**Result: deadlock persists.**  The queue only orders within a node, not
between nodes.  Cross-node, the holder-reacquire race still exists.

### 4. Agent-side Global Order (DENY on Out-of-Order)

Agent tracks held lock order keys.  If a node tries to acquire a lock
while holding a higher-key lock, send LOCK_DENY with reason STALE.

**Result: kernel panic.**  `gfs2_glock_complete(gl, -ESTALE)` treats STALE
as a fatal filesystem error (it was designed for fencing-token validation
failures).  GFS2 withdraws the filesystem.

### 5. Agent-side Global Order (WAIT on Out-of-Order)

Same ordering check, but send LOCK_WAIT instead of DENY.

**Result: no effect.**  LOCK_WAIT doesn't break the holder-reacquire race —
the waiter stays in LOCK_WAIT while the holder continues its release→
reacquire cycle.  Never progresses.

### 6. Agent-side Type-2/3 Order (WAIT)

Only enforce ordering between type=2 (inode) and type=3 (rgrp) locks,
which were believed to form the AB/BA pair.  Send LOCK_WAIT + BAST.

**Result: no effect.**  The "AB/BA" model was incorrect — the contention
is on a single lock (type=2, not type=2 vs type=3).  The ordering check
never fired because neither node held both types simultaneously.

### 7. Release All Type-2/3 on Contention

When CAS fails on a type-2 or type-3 lock and another node holds it,
release ALL held type-2/3 locks to break the cycle.

**Result: no effect.**  Same diagnosis — the contention is on a single
lock, not across types.  The release logic didn't trigger because the
"other type" wasn't held.

### 8. BAST Signal + HasWaiter Check in Self-contention

When CAS fails due to contention, write a bast key with the waiter's
nodeID.  In the self-contention handler, check `HasWaiter()` before
reacquiring.  If a waiter exists, yield (send LOCK_WAIT, watchAndRetry).

This approach evolved through several sub-iterations:

**8a: Check HasWaiter before release.**  TOCTOU race — both nodes check
before anyone writes the bast key.  Neither yields.

**8b: Check HasWaiter after release.**  Holder releases, then checks.
Closes the TOCTOU window.  Holder yields when bast found.

**Result: both nodes yielded.**  Node 1's bast key made Node 0 yield, but
Node 1's own self-contention (on retry) also saw the bast key and yielded.
Both ended up in watchAndRetry, neither acquired.  (Fixed by deleting the
bast key on yield — see #9.)

**8c: WatchAndRetry only handled DELETE events.**  After yielding, the
holder array was MODIFIED (one entry removed) but not DELETED.  The waiter's
watch didn't fire.  (Fixed by also handling PUT events in watchAndRetry.)

### 9. Atomic Handoff on Self-contention Yield (Current)

When `HasWaiter` returns true with a valid waiter nodeID, instead of
just sending LOCK_WAIT, atomically delete the lock key AND write a `/next`
handoff reservation via `HandoffRelease`:

```
Holder yields:
  Txn: IF lock_key.version > 0
       THEN Delete(lock_key), Put(/next, waiterID, lease=5s)
  → DeleteBastRequest
  → LOCK_WAIT
  → watchAndRetry

Waiter:
  watchAndRetry fires (DELETE from HandoffRelease)
  → CheckHandoff → YES (my ID)
  → DeleteHandoff
  → CAS → key empty → succeeds
```

The single etcd transaction guarantees the waiter wins — there's no race
window between the holder deleting the key and the waiter CASing.  The 5s
lease on `/next` prevents permanent reservation if the waiter crashes.

**Status: committed, untested on clean infra.**  The last deploy had a build
error (missing `strings` import in `client.go`) that was fixed but not
deployed to a working cluster.

## Summary

| # | Approach | Failure Mode |
|---|----------|-------------|
| 1 | BAST + handoff | Livelock |
| 2 | No BAST, wait | Holder-reacquire race |
| 3 | Kernel ordered queue | Per-node only |
| 4 | Global order + DENY | Kernel panic (ESTALE) |
| 5 | Global order + WAIT | No effect |
| 6 | Type-2/3 order + WAIT | Wrong diagnosis |
| 7 | Release all type-2/3 | Wrong diagnosis |
| 8 | HasWaiter + yield | TOCTOU + self-yield + watch events |
| 9 | Atomic handoff on yield | Untested |
