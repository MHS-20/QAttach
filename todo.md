## Status: single-key holder-array model implemented, multi-node reads working

### Working ✅

- **Single-key lock model** (one key per lock, JSON holder array) — clean release paths, no sub-key cleanup edge cases
- **Cross-node reads** (node1 reads files written by node0) ✅
- **BAST delivery end-to-end** ✅
- **Atomic handoff** (holder→waiter reservation) ✅
- **Self-contention handling** with other holders ✅
- **Journal ID CAS assignment** ✅
- **Go↔C struct padding** ✅
- **Agent PID re-registration** ✅
- **No more ExecStop umount** that bricks agent restart ✅

### Not yet working ❌

- **Node1 writes hang**: GFS2 metadata locks EX→SH demotion not guaranteed

### Bugs fixed

- Stale SH sub-keys blocking CAS after cross-node handoff → fixed by single-key holder-array model
- Dual-key lock model cleanup edge cases (4 release paths, 2 keys each) → eliminated
- Go↔C struct padding mismatch causing netlink message corruption → exported PadMnt/PadGrant/PadDeny
- Agent PID re-registration on restart breaking netlink communication → fix b44f23d
- ExecStop=umount in cluster-agent systemd unit bricking agent restart → removed
- Stale bast request keys not expiring → short lease (15s) on bast keys
- Handoff race: holder reacquiring before waiter → atomic /next reservation Txn

### Script issues tracked

- **`destroy-infra.sh`**: Key pair deletion removed (shared resource). Still
  need to make it conditional (only delete if created by create-infra.sh).
- **`create-infra.sh`**: Now saves `etcd_public_ips` and `compute_public_ips`.
- **`setup-compute.sh`**: Now uses public IPs for SSH (falls back to private).
- **`launch.sh`**: Fixed `~` path under sudo, removed `mount.gfs2` from packaging.
- **`mkfs.gfs2`**: pagure.io version doesn't support `-p lock_etcd`.
  Workaround: format with `-p lock_dlm`, mount with `-o lockproto=lock_etcd`.
