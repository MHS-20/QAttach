#!/usr/bin/env bash
# mount-all.sh — mount the shared GFS2 image with lock_etcd on every node.
set -euo pipefail
here=$(dirname "$0")
for ((i = 0; i < ${NODES:-3}; i++)); do
  "$here/node.sh" "$i" 'mount -t gfs2 -o lockproto=lock_etcd /dev/vda /mnt/gfs2' 120
done
