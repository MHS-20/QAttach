# Known Limitation: Mount-Time Glocks Outside BAST Reach

## Problem

Certain GFS2 glocks are acquired internally by the kernel during filesystem
mount and held indefinitely. They never pass through the lock manager's
`letcd_lock()` during normal operation, so the agent never sees them and
never starts a BAST watcher for them. When another node later needs these
locks, the holder never yields — the BAST is written by the waiter, but
nobody is watching.

## Affected Glocks

| Type | Name    | Acquired during | Held for                     |
|------|---------|-----------------|------------------------------|
| 1    | Nondisk | Mount           | Superblock coordination      |
| 8    | Quota   | Mount / setattr | Quota file updates           |
| 9    | Journal | Mount           | Each node holds its own      |

## Reproduction

```bash
# Node 1 mounts
mount -t gfs2 -o lockproto=lock_etcd ... /dev/nvme1n1 /mnt/shared

# Node 2 mounts
mount -t gfs2 -o lockproto=lock_etcd ... /dev/nvme1n1 /mnt/shared

# Node 1: any metadata operation hangs
sudo chmod 777 /mnt/shared   # hangs in gfs2_glock_wait → gfs2_setattr
```

The `chmod` call enters `gfs2_setattr()` which calls `gfs2_qa_get(ip)` to acquire
the quota glock. `gfs2_qa_get` blocks in `gfs2_glock_wait` because Node 2 holds
the quota glock. The lock manager (`letcd_lock`) is never called — the kernel
debug probes confirm zero activity for the quota lock type on both nodes.

## Why the BAST Mechanism Doesn't Help

The BAST watch goroutine starts in `trackHeldLock()`, which is only called
when the agent explicitly acquires a lock via `AcquireLock()`. Mount-time
glocks are acquired by GFS2 internally; the kernel may call `lm_lock` once
during mount (before the agent registers its PID), but subsequent uses of
the cached glock bypass the lock manager entirely.

Even if the agent did run a BAST watcher for these locks, the kernel's
internal `gfs2_qa_get` path may not go through `letcd_lock` at all —
GFS2 can re-use a cached glock state without requesting the lock manager.

## Verified with Kernel Probes

`docs/debug/glock-hang-analysis.md` documents the full probe chain:

| Probe                     | Fired for quota/root? |
|---------------------------|------------------------|
| `gfs2_setattr` entry      | NO                    |
| `__gfs2_holder_init`      | NO                    |
| `gfs2_glock_nq`           | NO                    |
| `glock_work_func`         | NO                    |
| `letcd_lock`              | NO                    |

The lock manager is never reached. The hang is in GFS2's own glock layer.

## Mitigations

1. **Mount with `-o quota=off`** — avoids `gfs2_qa_get` for chmod, but the
   underlying issue (mount-time glock not mediated by BAST) remains for
   other glock types.

2. **Initiate BAST watch at agent startup for all held mount-time glocks**
   — the agent would need to know which glocks GFS2 acquired internally.
   The kernel module would need to report mount-time lock acquisitions
   to the agent.

3. **Patch GFS2's mount path to go through the lock manager for every
   internal glock** — invasive, requires GFS2 source modifications.
