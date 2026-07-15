# QAttach — Current Status & Next Steps

Updated: 2026-07-15

## What Was Fixed (v0.0.4)

The 2-node concurrent write deadlock is resolved. Test 3 (`run-full-test.sh`) passes consistently.

Fixes applied:

1. **ConvertLock** — in-place mode conversion (no release+reacquire window). When a node holds PR and
   the kernel requests EX, the agent atomically updates its etcd entry from PR→EX without releasing.
   If other PR holders exist, the conversion is queued with polling.

2. **Polling replaced etcd Watch** — etcd Watches silently failed to deliver events under load.
   Replaced with 200ms polling for lock acquisition and 1s for conversion retry.

3. **Inline-SH kernel fast-path** — types 1 (nondisk), 5 (IOPEN), and 8 (quota) get SH granted
   synchronously via `gfs2_glock_complete` inline, bypassing netlink entirely. Eliminates mount-time
   zombie holders for these types.

4. **BAST all conflicting PR holders** — the conversion path writes `/locks/bast/` keys to ALL
   nodes holding PR on the same lock, not just the first one.

5. **ReleaseLock infinite CAS retry** — was silently returning nil after 5 failed attempts.
   Now retries indefinitely until the version matches.

6. **Yield suppression removed** — the `gfs2_glock_complete(gl, 0)` path that created zombie
   holders is gone, along with the yield hash table, netlink messages, and kernel patches.

7. **Synchronous kernel wait** — `letcd_lock` blocks on a completion (5s timeout) for ALL modes.
   `dispatch_lock_grant`, `dispatch_lock_deny`, and `dispatch_lock_wait` all signal the completion
   so the kernel thread unblocks immediately.

## What's NOT Fixed: N-Node Contention (N > 2)

The 3-node randomized stress test (`run-randomized-test.sh 10 3 5`) hangs. Node 0 completes all
operations, nodes 1-2 enter D-state and never recover. The 2-node case works because with only two
contenders, one wins ConvertLock and the other falls back to release+retry, eventually acquiring.

With 3+ nodes, the agent's lock coordination has a race where:
- Node A wins ConvertLock, updates etcd to EX
- Nodes B and C both self-contend, fail ConvertLock, fall back to release+retry
- B and C both release their PR, becoming waiters polling `AcquireLock`
- A finishes, `HandleLockRelease` fires, `HandoffRelease` writes `/next` marker for the first waiter
- The designated waiter should acquire, but under sustained contention the polling never picks up
  the grant because the lock is never idle long enough

DLM avoids this by serializing all operations on a single resource via `lock_rsb(r)`. One thread
processes the entire state machine — no CAS races, no polling, no timing windows.

## Proposed Approaches for N-Node Fix

### Plan A: Per-resource etcd mutex

Use etcd's `concurrency.Mutex` so only one node's agent processes a given resource at a time.
The mutex holder reads current state, runs the full state machine (grant/convert/wait/BAST) locally,
writes the new state back to etcd, and releases the mutex.

**Pros**: Matches DLM's serialized model exactly. No CAS retries, no polling. Simple Go code.
**Cons**: Introduces a new infrastructure dependency (etcd mutex). If the mutex holder crashes,
the mutex must time out before another node can proceed (adds latency on failure).

### Plan B: Atomic etcd Txns for every transition

Replace the ConvertLock/polling/wait flow with a single etcd Txn per operation. The Txn itself
decides whether to grant, convert, queue, or deny — all atomically. No polling goroutines for
the critical path. On WAIT, a retry goroutine periodically re-runs the same Txn until granted.

```
ProcessLock Txn logic:
  IF key doesn't exist:             PUT → GRANTED
  IF we're already a holder:        IF can convert → update entry → GRANTED
                                    ELSE → update entry → WAIT
  IF we're NOT a holder:            IF compatible → append entry → GRANTED
                                    ELSE → WAIT

HandleLockRelease Txn logic:
  Remove our entry
  IF no holders AND waiters exist:  PUT first_waiter → send GRANT
  ELSE:                             PUT/delete as appropriate
```

**Pros**: Fits existing architecture. No new infrastructure. Built incrementally.
Single etcd round-trip per operation (no polling on fast path).
**Cons**: Txn logic is complex (handles many state transitions in one function).
The retry goroutine for WAIT still uses intervals.

### Plan C: Full in-kernel state machine (DLM clone)

Port DLM's `do_request`/`do_convert`/`do_unlock`/`grant_pending_locks` into the kernel. Each
node tracks all lock holders locally. Cross-node signals go through the agent only for
remote BAST and epoch tracking. No etcd per-operation — etcd used only for membership.

**Pros**: Maximum performance (no userspace round-trips for local grants). Most correct
(matches DLM exactly).
**Cons**: Massive effort (thousands of lines of kernel C). Years of testing to reach
DLM's reliability. Duplicates DLM's entire lock manager.

## Recommendation

Plan B is the pragmatic choice: atomic etcd Txns fit the existing architecture, require no new
infrastructure, and can be built incrementally. The kernel already has synchronous wait
(`letcd_lock` blocks on completion). The agent just needs one Txn per operation instead of
the current multi-step ConvertLock+poll+watch flow.
