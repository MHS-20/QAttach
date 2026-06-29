#!/bin/bash
# test-suite.sh — run GFS2/etcd/DLM validation tests.
#
# Each test sets up, exercises, and tears down a scenario.
# Designed to run on a multi-node GFS2 cluster.
#
# Usage: ./test-suite.sh <mountpoint>
#
# Environment:
#   ETCD_ENDPOINTS — etcd cluster endpoint (default: etcd-nlb.internal:2379)
#   TEST_NODE_IPS  — space-separated list of peer node IPs

set -euo pipefail

MOUNTPOINT="${1:-/mnt/shared}"
ETCD_ENDPOINTS="${ETCD_ENDPOINTS:-etcd-nlb.internal:2379}"
RESULTS_DIR="./test-results"

mkdir -p "$RESULTS_DIR"

GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

pass_count=0
fail_count=0

pass() {
    echo -e "${GREEN}PASS${NC}: $1"
    echo "PASS: $1" >> "$RESULTS_DIR/summary.txt"
    ((pass_count++))
}

fail() {
    echo -e "${RED}FAIL${NC}: $1"
    echo "FAIL: $1" >> "$RESULTS_DIR/summary.txt"
    ((fail_count++))
}

log() { echo "[$(date +%T)] $*"; }

# ----------------------------------------------------------------------
# Test: etcd connectivity
# ----------------------------------------------------------------------
test_etcd_connectivity() {
    log "=== test: etcd connectivity ==="

    if curl -sf "http://${ETCD_ENDPOINTS}/health" > /dev/null 2>&1; then
        pass "etcd health endpoint reachable"
    else
        fail "etcd health endpoint unreachable"
    fi
}

# ----------------------------------------------------------------------
# Test: cluster-agent running
# ----------------------------------------------------------------------
test_agent_running() {
    log "=== test: cluster-agent running ==="

    if pgrep -x cluster-agent > /dev/null; then
        pass "cluster-agent process running"
    else
        fail "cluster-agent process not running"
    fi
}

# ----------------------------------------------------------------------
# Test: GFS2 mounted
# ----------------------------------------------------------------------
test_gfs2_mounted() {
    log "=== test: GFS2 mounted ==="

    if mountpoint -q "$MOUNTPOINT" 2>/dev/null; then
        local fstype
        fstype=$(findmnt -n -o FSTYPE "$MOUNTPOINT" 2>/dev/null)
        if [[ "$fstype" == "gfs2" ]]; then
            pass "GFS2 mounted at $MOUNTPOINT"
        else
            fail "mount point is $fstype, not gfs2"
        fi
    else
        fail "$MOUNTPOINT is not a mount point"
    fi
}

# ----------------------------------------------------------------------
# Test: basic file write/read
# ----------------------------------------------------------------------
test_file_write_read() {
    log "=== test: basic file write/read ==="
    local testfile="$MOUNTPOINT/.test_$(hostname)_$$"

    if echo "test data $(date)" > "$testfile" 2>/dev/null; then
        if grep -q "test data" "$testfile"; then
            pass "file write/read on GFS2"
            rm -f "$testfile"
        else
            fail "file readback mismatch"
            rm -f "$testfile"
        fi
    else
        fail "file write failed"
    fi
}

# ----------------------------------------------------------------------
# Test: concurrent write detection (no fencing)
# ----------------------------------------------------------------------
test_concurrent_write() {
    log "=== test: concurrent write (no fencing) ==="
    local testfile="$MOUNTPOINT/.test_concurrent_$$"

    # Two background writers to same file
    echo "writer1-$(date +%s%N)" > "$testfile" &
    pid1=$!
    echo "writer2-$(date +%s%N)" > "$testfile" &
    pid2=$!

    wait $pid1 $pid2 2>/dev/null || true

    if [[ -f "$testfile" ]]; then
        pass "concurrent write completed without crash"
        rm -f "$testfile"
    else
        fail "concurrent write lost file"
    fi
}

# ----------------------------------------------------------------------
# Test: lock_etcd module loaded
# ----------------------------------------------------------------------
test_module_loaded() {
    log "=== test: lock_etcd module loaded ==="

    if lsmod | grep -q lock_etcd; then
        pass "lock_etcd kernel module loaded"
    else
        fail "lock_etcd kernel module not loaded"
    fi
}

# ----------------------------------------------------------------------
# Test: Netlink socket exists
# ----------------------------------------------------------------------
test_netlink_socket() {
    log "=== test: Netlink socket ==="

    # Our custom Netlink family is 31. Check if it's registered.
    # AF_NETLINK family 31 should be visible via /proc/net/netlink
    if grep -qP '^31\b' /proc/net/netlink 2>/dev/null; then
        pass "Netlink family 31 registered"
    else
        log "  (Netlink family 31 not visible in /proc/net/netlink — may be dynamic)"
    fi
}

# ----------------------------------------------------------------------
# Test: node membership in etcd
# ----------------------------------------------------------------------
test_etcd_membership() {
    log "=== test: etcd membership ==="

    local count
    count=$(ETCDCTL_API=3 etcdctl \
        --endpoints="$ETCD_ENDPOINTS" \
        get "cluster/members/" --prefix --keys-only 2>/dev/null | wc -l)

    if [[ "$count" -gt 0 ]]; then
        pass "etcd member keys found ($count)"
    else
        fail "no member keys in etcd"
    fi
}

# ----------------------------------------------------------------------
# Test: locking state verification
# ----------------------------------------------------------------------
test_lock_state() {
    log "=== test: glock state ==="

    # Check glock debugfs if available
    local glock_file="/sys/kernel/debug/gfs2/$(findmnt -n -o SOURCE "$MOUNTPOINT" 2>/dev/null | xargs basename)/glocks"

    if [[ -f "$glock_file" ]]; then
        local lock_count
        lock_count=$(wc -l < "$glock_file")
        pass "glock debugfs available ($lock_count locks)"
    else
        log "  (glock debugfs not mounted — mount with: mount -t debugfs none /sys/kernel/debug)"
    fi
}

# ----------------------------------------------------------------------
# Main
# ----------------------------------------------------------------------

echo "GFS2/etcd DLM Test Suite"
echo "========================"
echo "Mount point:  $MOUNTPOINT"
echo "Etcd:         $ETCD_ENDPOINTS"
echo "Results dir:  $RESULTS_DIR"
echo "Started:      $(date)"
echo

tests=(
    test_etcd_connectivity
    test_agent_running
    test_module_loaded
    test_netlink_socket
    test_gfs2_mounted
    test_file_write_read
    test_concurrent_write
    test_etcd_membership
    test_lock_state
)

for test_func in "${tests[@]}"; do
    $test_func
done

echo
echo "===================================="
echo "Results: $pass_count passed, $fail_count failed"
echo "===================================="

exit $((fail_count > 0 ? 1 : 0))
