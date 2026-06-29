#!/bin/bash
# mount-gfs2.sh — mount a GFS2 filesystem on a compute node.
#
# Usage: ./mount-gfs2.sh <device> <cluster:fsname> <mountpoint>
#
# Prerequisites:
#   - lock_etcd kernel module loaded
#   - cluster-agent running and connected to etcd

set -euo pipefail

DEVICE="${1:?Usage: $0 <device> <cluster:fsname> <mountpoint>}"
LOCKTABLE="${2:?Usage: $0 <device> <cluster:fsname> <mountpoint>}"
MOUNTPOINT="${3:?Usage: $0 <device> <cluster:fsname> <mountpoint>}"

if [[ ! -b "$DEVICE" ]]; then
    echo "ERROR: $DEVICE is not a block device" >&2
    exit 1
fi

if ! lsmod | grep -q lock_etcd; then
    echo "ERROR: lock_etcd module not loaded." >&2
    exit 1
fi

if ! pgrep -x cluster-agent > /dev/null; then
    echo "ERROR: cluster-agent not running." >&2
    exit 1
fi

mkdir -p "$MOUNTPOINT"

echo "Mounting $DEVICE → $MOUNTPOINT"
echo "  Lock table: $LOCKTABLE"

mount -t gfs2 \
    -o "lockproto=lock_etcd,locktable=${LOCKTABLE},noatime" \
    "$DEVICE" "$MOUNTPOINT"

echo "Mounted. Verify with: df -h $MOUNTPOINT"
