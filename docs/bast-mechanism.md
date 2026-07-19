# BAST Mechanism & Lock Contention

## Background

BAST (Blocking AST) is the DLM mechanism for informing a lock holder that another
node wants the lock. The holder receives a callback and demotes or releases the
lock. In QAttach, BAST is coordinated through etcd.

## Current Flow (post-yield-removal)

When node B wants a lock held by node A in an incompatible mode:

```
        Node A (holder)                    etcd                    Node B (waiter)
        ───────────────                    ────                    ───────────────
  1.    holds lock (EX)                   holders=[{A,EX}]
  2.                                                              lock request
  3.                                                              ProcessLock fails (EX conflict)
  4.                                                              write bast key + waiter entry
  5.                                                              send LOCK_WAIT to kernel
  6.                                                              start retryProcessLock goroutine
  7.    watchBastAndYield fires          bast key created
  8.    sends BAST to kernel
  9.    GFS2: glock_cb → run_queue → do_xmote(UNLOCKED)
 10.    letcd_lock(UNLOCK) → LOCK_REL
 11.    agent: HandoffRelease            Txn: delete key + write /next marker
 12.                                                              retryProcessLock sees /next → acquires
 13.                                                              sends GRANT to kernel
```

## BAST Request Keys

Path: `/locks/bast/{type}/{number}`
Value: `"targetMode,waiterID"`

The waiter writes this key via `RequestBast()`. The holder watches it via
`WatchLockBast()` with a per-lock goroutine spawned by `trackHeldLock`. The key
has a short lease (15s) so stale BAST requests auto-expire.

## FIFO Handoff

When the holder releases, `HandoffRelease` atomically deletes the lock key and
writes `/locks/glock/{type}/{number}/next` naming the oldest waiter (FIFO order
by CreateRevision). `ProcessLock` checks this marker: if a different node is
designated, the acquisition is refused. Only the designated node can claim,
atomically deleting the marker. This prevents holder-reacquire livelock.

## BAST Compatibility

BAST is always sent when there's contention — there is no `compatibleBastMode`
filter. The holder's GFS2 decides whether to comply with the demotion.

## Timeout Safety

`retryProcessLock` times out after 120s. On timeout, the waiter entry and any
`/next` handoff marker are cleaned up, and the kernel receives a DENY so GFS2
can proceed without the lock.

## Removed: Yield Mechanism

The old yield-based approach (LOCK_YIELD/YIELD_CLEAR messages, `yield_table` in
the kernel) was removed. It added complexity without solving the fundamental
race condition. The BAST→HandoffRelease→FIFO chain is simpler and correct.
