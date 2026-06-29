#!/bin/bash
# load-module.sh — load the lock_etcd kernel module.
#
# Usage: ./load-module.sh [etcd_endpoints]
#
# The module communicates with cluster-agent via Netlink; etcd endpoints
# are configured on the agent side, not here.  This script just ensures
# the module is built and loaded.

set -euo pipefail

MODULE="lock_etcd"
KERNEL_DIR="$(dirname "$0")/../kernel"

echo "Building $MODULE..."

make -C /lib/modules/$(uname -r)/build M="$(realpath "$KERNEL_DIR")" modules

echo "Loading $MODULE..."

if lsmod | grep -q "$MODULE"; then
    echo "  $MODULE already loaded, removing first..."
    rmmod "$MODULE" 2>/dev/null || true
fi

insmod "$KERNEL_DIR/${MODULE}.ko"

echo "Module loaded. Verify with: dmesg | tail -20"
lsmod | grep "$MODULE"
