#!/bin/bash
# add-journals.sh — dynamically add journals to a mounted GFS2 filesystem.
# No unmount needed.
#
# Usage: ./add-journals.sh <mountpoint> [count]
#
# Example: ./add-journals.sh /mnt/shared 4

set -euo pipefail

MOUNTPOINT="${1:?Usage: $0 <mountpoint> [count]}"
COUNT="${2:-4}"

if ! mountpoint -q "$MOUNTPOINT"; then
    echo "ERROR: $MOUNTPOINT is not a mount point" >&2
    exit 1
fi

FS_TYPE=$(findmnt -n -o FSTYPE "$MOUNTPOINT")
if [[ "$FS_TYPE" != "gfs2" ]]; then
    echo "ERROR: $MOUNTPOINT is not a GFS2 filesystem (found: $FS_TYPE)" >&2
    exit 1
fi

echo "Adding $COUNT journal(s) to $MOUNTPOINT"
gfs2_jadd -j "$COUNT" "$MOUNTPOINT"
echo "Done. Total journals:"
gfs2_edit -p journals "$(findmnt -n -o SOURCE "$MOUNTPOINT")" 2>/dev/null | head -20
