# BAST Mechanism & Lock Contention

## Background

BAST (Blocking AST) is the DLM mechanism for informing a lock holder that another
node wants the lock.  The holder receives a callback and decides whether to demote
or release the lock.  In QAttach, BAST is coordinated through etcd.

## The Contention Problem

When node B wants a lock held by node A in an incompatible mode, the etcd CAS
or Txn fails because the holder array already has an incompatible entry.  Node B's
agent must:

1. Signal node A that someone is waiting (BAST request)
2. Tell its local kernel to wait (LOCK_WAIT)
3. Watch for the lock to become available (watchAndRetry)

Without step 1, node A never knows to release, and node B waits forever.

## BAST Flow

```
        Node A (holder)                    etcd                    Node B (waiter)
        ───────────────                    ────                    ───────────────
  1.    holds lock (EX)                   holder array=[{A,EX}]
  2.                                                              lock request (SH)
  3.                                                              Txn fails (EX present in array)
  4.                                                              write bast key (target=SH)
  5.                                                              send LOCK_WAIT to kernel
  6.                                                              watch lock key
  7.    bast watch fires                 bast key created
  8.    reads target mode (SH)
  9.    sends BAST to kernel
 10.    GFS2: glock_cb(SH)
 11.    GFS2: letcd_lock(SH)
 12.    agent: release EX                Txn: remove A from array, add A with PR
 13.                                                              watch fires (array changed)
 14.                                                              Txn: append B with PR → succeeds
```

## BAST Request Keys

Path: `/locks/bast/{type}/{number}`
Value: target mode (integer: 0=UNLOCK, 1=EX, 2=DF, 3=SH)

The waiter writes this key.  The holder watches it.  The holder deletes it after
processing (typically in `releaseHeldLock` when the lock is actually released).

The waiter uses a short lease (15s) so stale bast requests auto-expire.

## The Livelock Problem

The flow above has a critical race condition:

```
Time  Holder (SH)                     etcd                  Waiter (wants EX)
────  ──────────────────────          ────                  ─────────────────
  1   holds SH (array=[{A,PR}])                             Txn fails → SH held
  2                                                          writes bast(UNLOCK)
  3   bast fires → sendBast(UNLOCK)
  4   GFS2: letcd_lock(UNLOCK)
  5   agent: delete from array ────  key deleted ────────  watch fires
  6   GFS2: glock work runs:
      "I still need EX"
  7   letcd_lock(EX)
  8   agent: CAS → succeeds ────────  array=[{A,EX}]
  9                                                          CAS → fails again
 10                                                          contention loop
```

**Root cause:** There's no ordering guarantee between the holder's reacquire
(step 7-8) and the waiter's retry (step 9).  The holder's GFS2 glock work
function runs independently and may reacquire EX before the waiter can CAS.
Since both see the same etcd state, the faster one wins — and the holder
is always faster because it runs in the same process as the release.

In DLM, this doesn't happen because the DLM is a central arbiter — it knows
the waiter is queued and grants to the waiter first.

## BAST Compatibility Rules

Not every contention should trigger a BAST.  The `compatibleBastMode` function
implements these rules:

| Holder | Requester | Action                          |
|--------|-----------|---------------------------------|
| EX     | SH        | BAST(SH) — EX can demote to SH  |
| EX     | EX        | No BAST — no compatible mode    |
| EX     | DF        | No BAST — no compatible mode    |
| DF     | SH        | BAST(SH) — DF can demote to SH  |
| DF     | EX        | BAST(UNLOCK) — DF must release  |
| SH     | EX        | BAST(UNLOCK) — SH must release  |
| SH     | DF        | BAST(UNLOCK) — SH must release  |
| SH     | SH        | Compatible — no action needed   |

For EX+SH: the holder's GFS2 decides whether to comply.  The BAST is sent
but the holder may reacquire EX if it still needs it.

For EX+EX: no BAST is sent because EX cannot coexist with EX.  The waiter
must wait for the holder to release naturally (I/O completion, unmount, etc.).

## Implemented Solution: Atomic Handoff

To eliminate the race window, the holder's release must atomically reserve
the lock for the waiter.  The handoff token is at `/locks/glock/{type}/{number}/next`
with the waiter's nodeID.

```
Holder releases (BAST-triggered) in a single etcd Txn:
  IF (lock key Version matches AND I am in the holder array)
  THEN:
    1. Remove my entry from the holder array
    2. If array is now empty, Delete the lock key
    3. Put /locks/glock/{type}/{number}/next = waiterID (lease=5s)

Waiter watches:
  if /next appears with my ID → I have priority, Txn succeeds
  if lock key deleted/modified without /next → normal retry
```

The holder's release transaction deletes the lock key (if all holders removed)
and writes the handoff token atomically.  The 5s lease prevents permanent
reservation if the waiter crashes.  The transaction is atomic: either the
holder holds the lock OR the handoff token exists — never both, never neither.

This guarantees the waiter wins the race because:
1. Holder atomically removes self from array + writes handoff
2. Holder's glock work runs, tries to CAS → fails (handoff exists)
3. Waiter's watch fires on /next → Txn → succeeds
4. Waiter deletes /next

The holder can only reacquire after the handoff expires (if waiter crashes)
or after the waiter acquires (holder watches for the waiter's acquisition).

## Persistent BAST Watch

The bast watch goroutine must stay alive, not exit after the first BAST.
If GFS2 reacquires EX after a BAST was processed, the holder may receive
additional BAST requests (from the same or different waiters).  The watch
only exits when the lock is released (context cancelled).
