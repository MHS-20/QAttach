#!/bin/bash
# glock-top.sh — live glock contention monitor.
#
# Usage: ./glock-top.sh [mountpoint]
#
# Shows real-time glock state from debugfs. Requires debugfs mounted.

set -euo pipefail

MOUNTPOINT="${1:-/mnt/shared}"
FSNAME=$(findmnt -n -o SOURCE "$MOUNTPOINT" 2>/dev/null | xargs basename)
GLOCK_FILE="/sys/kernel/debug/gfs2/${FSNAME}/glocks"

if [[ ! -f "$GLOCK_FILE" ]]; then
    echo "ERROR: glock debugfs not available at $GLOCK_FILE" >&2
    echo "Mount debugfs: mount -t debugfs none /sys/kernel/debug" >&2
    exit 1
fi

echo "GFS2 glock monitor — $FSNAME"
echo "Refresh: every 2s | Ctrl-C to exit"
echo

while true; do
    clear
    echo "=== GFS2 Glocks: $FSNAME ($(date +%T)) ==="

    # Count by state
    echo "Held locks by state:"
    grep -oP 's:[A-Z]{2}' "$GLOCK_FILE" | sort | uniq -c | sort -rn

    echo
    echo "Recent lock activity (last 20 entries):"
    tail -20 "$GLOCK_FILE"

    sleep 2
done
