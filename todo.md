## Status: Kernel rebuilt & deployed. Single-node works. Multi-node blocked by missing BAST.

### What was accomplished

- **Kernel rebuild**: Custom kernel 6.18.35 with lock_etcd compiled in-tree (PID fix b44f23d). Uploaded to S3: `s3://muhamad-tirocinio-bucket-.../kernel-6.18.35-custom.tar.gz`
- **Infra**: 3 etcd + 2 compute nodes created, etcd cluster healthy, custom kernel deployed ✅
- **Single-node GFS2 mount**: Works — lock_etcd netlink communication functional ✅
- **Agent PID re-registration**: Works — fix b44f23d confirmed effective ✅

### Bugs discovered & fixed

#### 1. Go `binary.Write` skips unexported struct fields [FIXED]
**Symptom**: Mount timed out because `MountResponse` was 12 bytes (Go) vs 16 bytes (C), failing kernel's `plen >= 4 + sizeof(...)` check.
**Root cause**: Go `encoding/binary.Write` silently skips unexported fields (starting with `_`). The `_pad` fields meant to add C-compatible trailing padding were ignored.
**Fix**: Renamed `_pad` → exported `PadMnt`, `PadGrant`, `PadDeny` in `pkg/protocol/netlink.go`.
**Other affected structs**: `LockGrant` (Go 20B → C 24B), `LockDeny` (Go 12B → C 16B).

#### 2. `scripts/kernel/launch.sh` uses `~` under sudo [FIXED]
**Symptom**: `modules_install` step fails with "No such file or directory".
**Root cause**: The `run()` function uses `sudo bash -s`, so `~` expands to `/root` instead of `/home/ec2-user`.
**Fix**: Changed `~/rpmbuild/...` to `/home/${SSH_USER}/rpmbuild/...` for the `run` calls at lines 213-224.
**Also**: Removed `mount.gfs2` from packaging (pagure.io gfs2-utils doesn't build it).

#### 3. `mkfs.gfs2` doesn't support `lock_etcd` protocol [WORKAROUND]
**Symptom**: `mkfs.gfs2 -p lock_etcd` fails with "Invalid lock protocol: lock_etcd".
**Root cause**: pagure.io gfs2-utils validates protocols against `lock_dlm`/`lock_gulm` only.
**Fix needed**: Patch `gfs2/mkfs/main_mkfs.c` to add `lock_etcd` to `table_required` check.
**Workaround**: Format with `-p lock_dlm` (default), mount with `-o lockproto=lock_etcd`. The kernel uses the mount option, not the superblock value.

#### 4. `destroy-infra.sh` deletes pre-existing key pair [FIX NEEDED]
**Symptom**: Teardown deleted the shared `muhamad-keypair` key pair.
**Fix needed**: Only delete key pair if it was created by `create-infra.sh` (track in state).

### Blocking issue: BAST (lock downgrade) not sent by agent

**Symptom**: Second compute node cannot mount because locks held by first node are never released.
**Root cause**: When a lock is contended (etcd CAS fails), the agent sends `LockWait` to the requesting node, but NEVER sends `SendBast` to the lock holder. Without BAST, the holder never knows to downgrade/release, and the waiter waits forever.
**What's needed**: In `internal/lock/manager.go`, after detecting lock contention, call `nlSrv.SendBast()` to the lock holder with target mode. The kernel processes BAST via `dispatch_bast()` → `gfs2_glock_cb()` which triggers GFS2's lock demotion.

### Other notes

- **etcd membership**: Keys stored under lease. Agent restart revokes old lease, new agent creates new keys. Fencing races occur when both agents restart simultaneously.
- **Systemd ExecStop**: The `ExecStop=/bin/umount /mnt/shared` causes GFS2 unmount on agent restart, which hangs if locks can't be acquired.
