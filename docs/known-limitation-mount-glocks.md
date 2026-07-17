# Known Limitation: Mount-Time Glocks (Resolved)

**Status: PARTIALLY RESOLVED**

## Original Problem

Mount-time glocks (type=1 nondisk, type=8 quota, type=9 journal) were acquired
by GFS2 internally during mount and the agent never started a BAST watcher for
them.  When another node later needed these locks, the holder never yielded.

## Resolution for MOUNT Lock (type=1 num=0)

GFS2 acquires the MOUNT lock (`GFS2_MOUNT_LOCK`, type=1 num=0) in EX mode
during `gfs2_fill_super`.  At the end of `fill_super`, GFS2 calls
`gfs2_glock_dq_uninit(&mount_gh)` to release it (confirmed in upstream GFS2
source, `ops_fstype.c`).

**Fix:** `HandleLockRelease` and `releaseHeldLock` in the agent now always call
`ReleaseLock` on etcd, even for locks not tracked in the local `heldLocks` map.
This ensures the MOUNT lock's etcd key is cleaned up when GFS2 frees the glock.

**Result:** Multi-node mount works.  All 3 nodes can mount GFS2 concurrently.

## Remaining Issue: Inode Glocks Freed from Cache

When GFS2 frees an inode glock from the LRU cache, `letcd_put_lock` is called
which sends `LOCK_REL` via netlink.  The agent processes the release and cleans
the etcd key.  So inode glock release works correctly.

However, if a BAST arrives AFTER the glock was freed but BEFORE `letcd_put_lock`
completed (race window), the BAST arrives at the kernel which can't find the
glock in the bast list.  The BAST is silently discarded.

**Kernel fix (Option A):** The kernel module now keeps glocks in the bast list
across UNLOCK→ACQUIRE cycles by removing `letcd_bast_remove` from the UNLOCK
path (`letcd_lock`) and keeping it only in `letcd_put_lock`.  The BAST for
cached glocks now finds the glock and triggers demotion.
