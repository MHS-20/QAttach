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
Value: `"targetMode,waiterID"` (comma-separated string, e.g. `"0,i-0f620a6db190e05ce"`)

The waiter writes this key via `RequestBast()`.  The holder watches it via
`WatchLockBast()`.  The key has a short lease (15s) so stale BAST requests
auto-expire if the waiter crashes.

The target mode is currently always 0 (UNLOCK), matching DLM's behavior for
EX lock requests — the holder must release entirely.

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

## Implemented Solution: Persistent Yield + Handoff Watch

The solution combines three mechanisms:

### 1. Proactive BAST watcher per held lock

Every time the agent acquires a lock, `trackHeldLock()` spawns a
`watchBastAndYield` goroutine that watches `/locks/bast/{type}/{num}`
in etcd. When another node writes a BAST, the watcher fires
immediately — no need to wait for self-contention.

### 2. Persistent yield flag in the kernel

When the agent detects a BAST, it sends:
- `BAST(UNLOCK)` to the kernel → triggers `gfs2_glock_cb` to delock the lock
- `LOCK_YIELD` to the kernel → sets yield flag for this lock
- Then waits for the kernel to process the BAST (via `<-ctx.Done()`)

The kernel's `letcd_lock()` checks the yield flag on reacquire attempts when
`gl_state == LM_ST_UNLOCKED` — conversions (EX→SH) pass through. The flag is
not auto-cleared — it persists until the agent sends `YIELD_CLEAR`.

### 3. Handoff completion watch

After yielding, `watchBastAndYield` watches the lock etcd key for the
handoff to complete (lock key deleted = all holders gone, or BAST lease expires).
When either happens, the agent sends `YIELD_CLEAR` to the kernel and the
lock can be reacquired.

```
Holder agent (node A):                   Waiter agent (node B):
  watchBastAndYield runs                   AcquireLock fails → write bast
  bast watch fires                         send LOCK_WAIT to kernel
  → sendBast(UNLOCK) to kernel             watch lock key
  → sendLockYield to kernel
  → wait for ctx.Done() (kernel processes BAST)
                                           ctx cancelled by releaseHeldLock
  lock key released via self-contention    (from self-contention or release)
  → watch lock key for handoff complete
                                           lock key changes → retry → succeeds
                                           does I/O → releases
  lock key deleted → sendYieldClear
  kernel: yield flag cleared → reacquire OK
```

### 4. BAST expiry safety net

If the waiter crashes before acquiring, the BAST key expires after its
15s lease. The holder's `watchBastAndYield` watches for this and sends
`YIELD_CLEAR` on BAST key deletion, allowing the holder to reacquire.

### Why this beats the old approach

| Old (atomic handoff) | New (persistent yield + watch) |
|---|---|
| Handoff token at `/next` with 5s TTL | No handoff token needed |
| Holder reacquires after handoff expires | Yield persists until YIELD_CLEAR |
| Race window between delete and handoff | Kernel suppresses ALL reacquires |
| Waiter must check handoff token | Waiter just watches lock key |

