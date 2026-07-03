# Debug Log Analysis — chmod Hang (2026-07-03)

## What we observed

A `sudo chmod 777 /mnt/shared` on N1 hung in `gfs2_glock_wait → gfs2_setattr`.
Kernel debug logging was added to `letcd_lock()` and the ordered queue.

## Key findings from dmesg

### 1. letcd_lock was NEVER called for the root inode (type=2, num=2)

- 63 `lock_etcd:` log entries captured
- All entries were for journal flush locks: (2,33384) every 30s, and one (2,33390)
- Zero entries for (2,2) — the root inode
- This means GFS2's glock state machine never requested a lock manager transition

### 2. The ordered queue is NOT the bottleneck

- Every drain completed immediately (DRAIN-WAIT → DRAIN-DONE, zero loops)
- No DRAIN-BLOCKED entries
- The (2,33390) WAIT re-insert did not block subsequent acquisitions
  because (2,33384) had a lower order key and drained first

### 3. No cross-node contention events

- Zero BAST entries
- Zero YIELD entries  
- Zero YIELD-SUPPRESS entries
- The cross-node mechanism was never triggered

### 4. Agent was alive and responsive

- Agent processed (2,33384) EX acquire→GRANT→UNLOCK every 30s
- NL-SENT ret=0 on every message (netlink delivery confirmed working)

## Conclusion

The hang is in GFS2's glock layer, **before** the lock manager is called.
`gfs2_setattr` → `gfs2_glock_nq_init(gl, LM_ST_EXCLUSIVE, ...)` queued an EX holder,
but the glock work function never called `lm_lock` to initiate the SH→EX transition.

The glock's internal state machine is stalled — likely `gl_target` does not match
`gl_state` in a way that triggers the lock manager, or a prior state machine
transition was never completed.

## Next step

Add debug probes to GFS2's `gfs2_glock_nq` and glock work function in `fs/gfs2/glock.c`
to dump `gl_state`, `gl_target`, `gl_req`, flags, and holder count before/after
queueing. This will show the exact glock state that prevents the transition.
