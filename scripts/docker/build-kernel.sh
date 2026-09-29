#!/usr/bin/env bash
# build-kernel.sh — build a KVM guest kernel with GFS2 and lock_etcd built in.
# Runs inside the qattach-docker image; see run.sh. Output: $WORK/bzImage.
set -euo pipefail

KVER=${KVER:-6.18.54}
WORK=${WORK:-/work}
REPO=${REPO:-/repo}
SRC=$WORK/linux-$KVER
GFS2=$SRC/fs/gfs2

if [[ ! -d $SRC ]]; then
  curl -fsSL "https://cdn.kernel.org/pub/linux/kernel/v${KVER%%.*}.x/linux-$KVER.tar.xz" | tar -xJ -C "$WORK"
  cat >>"$GFS2/Kconfig" <<'KEOF'

config GFS2_FS_LOCKING_ETCD
	bool "GFS2 etcd-backed locking (lock_etcd)"
	depends on GFS2_FS
KEOF
  # shellcheck disable=SC2016 # a literal Makefile variable
  echo 'gfs2-$(CONFIG_GFS2_FS_LOCKING_ETCD) += lock_etcd_main.o lock_etcd_netlink.o lock_etcd_glock.o lock_etcd_mount.o lock_etcd_lock.o' >>"$GFS2/Makefile"
  # Only the registration patches: the glock/inode debug hooks in
  # patch-kernel.py log every holder and would flood the console.
  python3 -c "import sys; sys.argv=['', '$SRC']; exec(open('$REPO/scripts/kernel/patch-kernel.py').read().split(\"if __name__\")[0]); patch_main('$GFS2/main.c'); patch_ops('$GFS2/ops_fstype.c')"
fi

# Sources are recopied every run so kernel/ edits are picked up.
cp "$REPO"/kernel/*.c "$REPO"/kernel/*.h "$GFS2/"

cd "$SRC"
if [[ ! -f .config ]]; then
  make -s defconfig kvm_guest.config
  ./scripts/config -e CONFIGFS_FS -e GFS2_FS -e GFS2_FS_LOCKING_ETCD -e NET_9P -e NET_9P_VIRTIO \
    -e 9P_FS -e 9P_FS_POSIX_ACL -e VIRTIO_BLK -e VIRTIO_NET -e TMPFS -e DEVTMPFS -e DEVTMPFS_MOUNT \
    -e DLM -e GFS2_FS_LOCKING_DLM -d DEBUG_INFO -d DEBUG_INFO_DWARF5 -d DEBUG_INFO_BTF
  make -s olddefconfig
fi
grep -q '^CONFIG_GFS2_FS_LOCKING_ETCD=y' .config
make -s -j"$(nproc)" bzImage
cp arch/x86/boot/bzImage "$WORK/bzImage"
echo "built $WORK/bzImage ($KVER)"
