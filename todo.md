Status: LOCK_YIELD kernel mechanism implemented, packaging pipeline broken
What's committed (will work when kernel is properly deployed)

- Single-key holder-array lock model — one etcd key per lock, JSON holder array
- Journal ID CAS assignment via /cluster/journals/{jid} — unique per node
- Go↔C struct padding — exported PadMnt/PadGrant/PadDeny
- Agent PID re-registration on restart — fix b44f23d
- No ExecStop umount in systemd unit — agent restart doesn't brick GFS2
- LOCK_YIELD auto-set on every letcd_lock(LM_ST_UNLOCKED) — kernel reacquire is suppressed, waiter gets the lock, agent clears yield via YIELD_CLEAR after acquire
- Yield dispatch in kernel (lock_etcd_glock.c), netlink messages 12/13, Go agent calls SendLockYield/SendYieldClear

Remaining: kernel packaging pipeline
The kernel builds but the archive on S3 (kernel-6.18.35-custom.tar.gz) needs to include the NEW gfs2.ko with yield symbols. Current issue:

1. Builder's make modules_install puts modules under /lib/modules/6.18.35-68.127.amzn2023.x86_64/
2. But compute nodes boot with uname -r = 6.18.35 (just the base)
3. So the archive's /lib/modules/6.18.35/ still has the OLD gfs2.ko from the previous build

Fix needed: verify the module path in the tar matches what compute nodes expect. Either:

- Copy gfs2.ko from the full version path to /lib/modules/6.18.35/ before packaging
- Or symlink /lib/modules/6.18.35.68.127.../gfs2/gfs2.ko → /lib/modules/6.18.35/gfs2/gfs2.ko in the archive
Script issues
- create-infra.sh: volume size bumped to 30GB (was 10GB, new AL2023 AMI requires 30GB)
- destroy-infra.sh: key pair deletion removed (shared resource)
- setup-compute.sh: ExecStop umount removed, uses public IPs for SSH
- launch.sh: ~ path fixed for modules_install under sudo
- mkfs.gfs2: pagure.io doesn't support -p lock_etcd — workaround: format with -p lock_dlm, mount with -o lockproto=lock_etcd
