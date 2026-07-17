# QAttach Status Report — July 2026

## What Works

| Feature | Status | Notes |
|---------|--------|-------|
| 1-node GFS2 mount | ✅ Working | Reliable with sequential agent startup |
| 3-node GFS2 mount | ✅ Working | MOUNT lock released correctly at end of `fill_super` |
| Heartbeat lock handoff | ✅ Working | BAST→UNLOCK→GRANT cycles every 30s on all 3 nodes |
| Agent-side FIFO handoff | ✅ Working | `/next` marker enforces ordering; chain node0→node1→node2 confirmed |
| Light concurrent I/O | ✅ Working | 1 op/5s per node, 3 shared files — 100% pass rate, 0 D-state |
| Kernel BAST for heartbeat | ✅ Working | BAST triggers demotion via `run_queue` for cached glocks |
| Kernel BAST for inode glocks | ✅ Working | Option A fix: `bast_remove` moved from UNLOCK to `put_lock` only |
| Lock mode mapping | ✅ Correct | EX=1, SH=3 matches GFS2 source (confirmed in `glock.h`) |
| Agent startup determinism | ✅ Working | Sequential startup with `wait_for_agent_ready` (3 checks) |
| Kernel deployment | ✅ Working | `deploy-kernel.sh` includes depmod, grub2-mkconfig, verification |

## What Has Issues

| Feature | Status | Notes |
|---------|--------|-------|
| High-frequency concurrent I/O | ⚠️ Limited | 10 ops/s stress test deadlocks; throughput limited by etcd latency |
| Kernel TRY handler | ⚠️ Inactive | `LM_FLAG_TRY` not set by GFS2 on this kernel version for journal locks |
| Kernel JRNL-DENY | ⚠️ Ineffective | Code present but never executes (mount_jid memory ordering issue) |
| `hasExistingData` restart | ⚠️ Buggy | Writes initial-cluster with all 3 members for single-node clusters |
| `isEndpointHealthy` | ⚠️ Leaky | Creates new etcd client every 2s during health check |
| Ordered list cleanup | ❌ Missing | `letcd_ordered_cleanup()` not implemented for unmount drain |

## What We Learned

1. **The lock mode constants were never inverted.** The AGENTS.md claim that "GFS2 has SH=1, EX=3" was wrong. GFS2 source (`glock.h`) has `LM_ST_EXCLUSIVE=1, LM_ST_SHARED=3`. Our original code was correct. The "fix" that swapped them was a regression.

2. **Multi-node mount works because GFS2 releases the MOUNT lock.** At the end of `gfs2_fill_super`, GFS2 calls `gfs2_glock_dq_uninit(&mount_gh)`. Our agent was dropping the release because the lock wasn't in `heldLocks`. Fixing `HandleLockRelease` to always clean up etcd resolved this.

3. **Concurrent I/O works because BAST→UNLOCK works for cached glocks.** The kernel module was removing glocks from the bast list on UNLOCK (`letcd_lock`), so subsequent BASTs couldn't find them. Moving `bast_remove` to `letcd_put_lock` only (Option A) keeps glocks in the bast list across UNLOCK→ACQUIRE cycles.

4. **FIFO ordering is enforced by the `/next` marker.** `ProcessLock` checks the handoff marker before fresh acquisition. If a marker exists for a different node, acquisition is refused. This prevents the live-lock where the releasing node immediately reacquires.

5. **The agent-side architecture is correct.** BAST signaling, FIFO handoff, release cleanup, and mode handling all follow DLM's patterns. The remaining throughput limit is the inherent latency of etcd vs. in-kernel DLM.

## Kernel Module Status

The current kernel module (`gfs2.ko` with lock_etcd built in) has these patches applied:
- Inline-SH fast-path for types 1, 5, 8 (inside yield block — needs moving)
- TRY handler with `LM_OUT_TRY_AGAIN` (0x20)
- JRNL-DENY based on `mount_jid` (currently ineffective)
- Option A: bast entry kept across UNLOCK→ACQUIRE cycles
- Netlink family 31 with PID tracking
- Ordered list for lock request serialization

See `AGENTS.md` for the complete commit history and remaining todo items.
