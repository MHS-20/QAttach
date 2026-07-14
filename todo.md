# QAttach — Current Status & Next Steps

Updated: 2026-07-09

## Where We Stand

Multi-node concurrent write test hangs in `gfs2_create_inode → gfs2_glock_wait`. The hang is caused by
two interacting problems:

1. **Zombie glock holders:** `letcd_lock`'s YIELD-SUPPRESS path calls `gfs2_glock_complete(gl, 0)`
   which leaves orphaned holders on `gl_holders`. `find_first_holder()` returns these zombies
   forever, blocking `run_queue` from ever calling `letcd_lock(UN)`.

2. **Non-deterministic handoff:** The 500ms timer + free-for-all etcd CAS race on reacquire means
   the first waiter doesn't always get the lock, causing livelock under sustained 3-node contention.

## In-Progress Fix: FIFO Wait Queue (agent-only, no kernel changes)

### Why yield suppression is unnecessary

DLM has no yield suppression. When a DLM lock is demoted via BAST, `gdlm_lock(UN)` sends an
unlock to DLM, and any subsequent reacquisition (e.g. a new `readdir` requesting SH) goes through
`gdlm_lock(SH)` which DLM serialises via its internal wait queue. GFS2's in-cache `may_grant`
does NOT bypass this for reacquisitions because:

- After `letcd_lock(UN)` → `gfs2_glock_complete(gl, 0)`, the glock's `gl_state` becomes 0.
- `may_grant(UNLOCKED, SH)` returns false (gl_state != gh_state), so the SH request goes through
  `lm_lock` → agent → FIFO queue.
- In-cache SH grants (`may_grant(SH, SH) = true`) only occur while the glock is already in SH
  state. These holders are short-lived (microseconds) and do not affect etcd lock state. They merely
  delay the UNLOCK until all readers finish — identical to DLM behaviour.

### FIFO design

Each lock resource gets a wait prefix key. Waiters register with their session lease.
When the holder releases, all waiters watch the lock key. The one with the lowest etcd
CreateRevision tries to acquire. If the first waiter crashed (lease expired, key gone),
the next waiter by revision naturally becomes first.

```
/locks/glock/{type}/{number}            → holder node ID (single-holder model)
/locks/glock/{type}/{number}/wait/{id}  → exists=waiting, lease=session TTL
/locks/bast/{type}/{number}             → cross-node signal (existing)
```

**Acquire flow:**
1. Try etcd Txn: if lock_key doesn't exist, PUT lock_key = my_nodeID
2. If Txn fails → PUT wait_key (lease), PUT bast_key (signal holder), send WAIT to kernel
3. Start goroutine watching lock_key
4. On DELETE: GET all wait_keys sorted by CreateRevision
   - If I'm first: try Txn acquire → on success, delete my wait_key, send GRANT
   - If I'm not first: continue watching
5. On PUT: check if value contains my nodeID
   - If yes: send GRANT (handled by the acquiring goroutine)
   - If no: continue watching (someone else got it)

**Release flow (holder):**
1. BAST key appears → send BAST to kernel (gfs2_glock_cb(UN)), delete bast key
2. Wait for HandleLockRelease from kernel (letcd_lock(UN) → LOCK_REL)
3. Delete lock_key from etcd → all waiters' watches fire → first waiter acquires
4. Done — no reacquire, no yield, no timers

## What Will Be Changed

### Agent (Go)
- `internal/etcd/client.go`: add AddWaiter, RemoveWaiter, GetWaiters, IsFirstWaiter
- `internal/lock/manager.go`: rewrite watchForLock, simplify watchBastAndYield,
  remove yield/timer/handoff complexity
- `pkg/protocol/etcd.go`: add PrefixWait key
- Remove yield netlink messages from Go side

### Kernel (C)
- Remove yield suppression from `kernel/lock_etcd_lock.c`
- Remove yield hash table from `kernel/lock_etcd_glock.c`
- Remove yield declarations from `kernel/lock_etcd_internal.h`
- Remove yield cleanup from `kernel/lock_etcd_mount.c`
- Remove yield message types from `kernel/letcd_netlink.h`
- Remove yield dispatch from `kernel/lock_etcd_netlink.c`

### Kernel patches
- Remove `may_grant` yield check and `run_queue` holder drain from `patch-kernel.py`
- Keep debug logging (gfs2_glock_nq, glock_work_func, __gfs2_holder_init, setattr)

## What Has Been Tried (and discarded)

1. **yield suppression + may_grant patch**: created zombie holders
2. **run_queue holder drain patch**: didn't fix the root cause
3. **5-second holdoff**: timer-based, not deterministic
4. **500ms backoff + PUT→DELETE tracking**: added complexity without fixing the race

## Next Steps After This Fix

- Deploy new kernel (without yield infrastructure)
- Install updated agent
- Run `scripts/infra/run-full-test.sh` with 3 nodes
- Run `scripts/infra/run-randomized-test.sh` at increasing intensity
