# Glock Hang Analysis — chmod 777 /mnt/shared

## Test Setup

- Kernel 6.18.35 custom with lock_etcd in-tree + debug probes
- 2 compute nodes, 3 etcd nodes
- GFS2 on EBS io2 Multi-Attach (30GB)
- Probes: `gfs2_setattr` (inode.c), `__gfs2_holder_init` (glock.c),
  `gfs2_glock_nq` (glock.c), `glock_work_func` (glock.c),
  `letcd_lock` (lock_etcd_lock.c), ordered queue, netlink dispatch

## Result

`chmod 777 /mnt/shared` hung on N1 in `gfs2_glock_wait → gfs2_setattr`.

## Root Cause: gfs2_qa_get(ip)

`gfs2_setattr()` calls `gfs2_qa_get(ip)` **before** it calls `gfs2_glock_nq_init()`.
The probe placed right before `gfs2_glock_nq_init` **never fired** for the root 
inode (type=2 num=2). This means the hang is in `gfs2_qa_get`, which acquires
the inode's quota allocation glock.

`gfs2_qa_get` internally takes a glock on the quota data structure. If node2
holds this glock (e.g., from its own mount process), `gfs2_qa_get` blocks in
`gfs2_glock_wait` waiting for the quota glock to be released.

**The quota glock is type=8 — our BAST watch only runs on glocks acquired via
`trackHeldLock`, which only tracks locks the agent explicitly acquires. The
quota glock acquisition may go through a different path (kernel-internal) 
that doesn't trigger our BAST mechanism.**

## Full Timeline

```
1. gfs2_setattr(ip) called for root inode (type=2, num=2)
2. gfs2_qa_get(ip) → needs quota glock (type=8)
3. quota glock held by node2 → blocks in gfs2_glock_wait
4. NEVER reaches gfs2_glock_nq_init (probe confirms)
5. NEVER reaches letcd_lock (probe confirms)
6. Chmod hangs forever
```

## Evidence

| Probe | Fired for root inode (2,2)? | Fired for other locks? |
|-------|-----|------|
| `gfs2_setattr` | NO | YES (n=33390, journal I/O related) |
| `__gfs2_holder_init` | NO | YES (n=33384, 33390) |
| `gfs2_glock_nq` | NO | YES (n=33384, 33390) |
| `glock_work_func` | NO | YES (n=33384, 33390) |
| `letcd_lock` | NO | YES (n=33384, 33390) |

## What Works

- Both nodes mount successfully
- Journal assignment works (jid=0, jid=1)
- Periodic journal flush (type=2 n=33384) cycles every 30s on both nodes
- Agent processes locks normally
- Cross-node BAST mechanism works (tested: n=9 mount-time lock)

## Next Steps

1. Add `gfs2_qa_get` debug probe to confirm quota lock contention
2. Extend BAST watch to also cover quota glock (type=8) and superblock glock (type=1)
3. Alternative: disable quota (`mount -o quota=off`) to bypass the issue

