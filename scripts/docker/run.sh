#!/usr/bin/env bash
# run.sh — start a local lock_etcd test cluster in Docker: one etcd plus N
# QEMU/KVM guests sharing a GFS2-formatted raw image.  Run from the repo
# root on a host with /dev/kvm.  Drive the guests with node.sh.
#
#   scripts/docker/run.sh build   # image, kernel and agent
#   scripts/docker/run.sh up      # fresh disk + etcd + guests
#   scripts/docker/run.sh down
set -euo pipefail

WORK=${QATTACH_DOCKER_WORK:-$HOME/.cache/qattach-docker}
NODES=${NODES:-3}
REPO=$(cd "$(dirname "$0")/../.." && pwd)
IMAGE=qattach-docker
NAME=qattach-cluster

case ${1:-} in
build)
  mkdir -p "$WORK"
  docker build -q -t "$IMAGE" "$REPO/scripts/docker"
  docker run --rm -v "$REPO:/repo:ro" -v "$WORK:/work" "$IMAGE" /repo/scripts/docker/build-kernel.sh
  (cd "$REPO" && CGO_ENABLED=0 go build -o "$WORK/cluster-agent" ./cmd/cluster-agent)
  ;;
up)
  docker rm -f "$NAME" >/dev/null 2>&1 || true
  rm -rf "$WORK/ctl" "$WORK/shared.img"
  for ((i = 0; i < NODES; i++)); do mkdir -p "$WORK/ctl/node$i"; done
  truncate -s 2G "$WORK/shared.img"
  docker run -d --name "$NAME" --device /dev/kvm -v "$REPO:/repo:ro" -v "$WORK:/work" "$IMAGE" bash -c "
    mkfs.gfs2 -O -p lock_dlm -t mycluster:fs -j $NODES /work/shared.img >/work/ctl/mkfs.log 2>&1
    etcd --data-dir /tmp/etcd --listen-client-urls http://0.0.0.0:2379 \
      --advertise-client-urls http://10.0.2.2:2379 >/work/ctl/etcd.log 2>&1 &
    sleep 1
    for ((i = 0; i < $NODES; i++)); do
      qemu-system-x86_64 -enable-kvm -cpu host -m 768 -smp 2 -display none -no-reboot \
        -kernel /work/bzImage \
        -append \"console=ttyS0 root=rootfs rootfstype=9p rootflags=trans=virtio,version=9p2000.L ro init=/repo/scripts/docker/guest-init.sh qattach.node=\$i panic=-1\" \
        -fsdev local,id=root,path=/,security_model=none,readonly=on \
        -device virtio-9p-pci,fsdev=root,mount_tag=rootfs \
        -virtfs local,path=/work/ctl/node\$i,mount_tag=ctl,security_model=none \
        -drive file=/work/shared.img,format=raw,if=none,id=disk,cache=none,file.locking=off \
        -device virtio-blk-pci,drive=disk,share-rw=on \
        -netdev user,id=net -device virtio-net-pci,netdev=net \
        -serial file:/work/ctl/node\$i/console.log &
    done
    wait"
  for ((i = 0; i < NODES; i++)); do
    until [[ -f $WORK/ctl/node$i/state ]]; do sleep 1; done
  done
  echo "cluster up: $NODES nodes"
  ;;
down)
  docker rm -f "$NAME" >/dev/null
  ;;
*)
  echo "usage: $0 build|up|down" >&2
  exit 2
  ;;
esac
