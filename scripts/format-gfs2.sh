#!/bin/bash
# format-gfs2.sh — format a GFS2 filesystem using lock_etcd.
# Run once, on one node only.
#
# Usage: ./format-gfs2.sh <device> <cluster:fsname> [journal_count]
#
# Example: ./format-gfs2.sh /dev/nvme1n1 mycluster:sharedfs 16

set -euo pipefail

DEVICE="${1:?Usage: $0 <device> <cluster:fsname> [journal_count]}"
LOCKTABLE="${2:?Usage: $0 <device> <cluster:fsname> [journal_count]}"
JOURNALS="${3:-16}"

if [[ ! -b "$DEVICE" ]]; then
    echo "ERROR: $DEVICE is not a block device" >&2
    exit 1
fi

echo "Formatting $DEVICE with lock_etcd protocol"
echo "  Lock table:   $LOCKTABLE"
echo "  Journals:     $JOURNALS"

# Ensure the kernel module is loaded
if ! lsmod | grep -q lock_etcd; then
    echo "ERROR: lock_etcd module not loaded. Run load-module.sh first." >&2
    exit 1
fi

# Ensure cluster-agent is running
if ! pgrep -x cluster-agent > /dev/null; then
    echo "ERROR: cluster-agent not running. Start it before formatting." >&2
    exit 1
fi

mkfs.gfs2 \
    -p lock_etcd \
    -t "$LOCKTABLE" \
    -j "$JOURNALS" \
    "$DEVICE"

echo "Format complete."
echo "Next: run mount-gfs2.sh on each compute node."
