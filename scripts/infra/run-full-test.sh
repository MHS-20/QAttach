#!/bin/bash
# run-full-test.sh — end-to-end test orchestration.
#
# Prerequisites: create-infra.sh + deploy-kernel.sh + setup-compute.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$SCRIPT_DIR/state.sh"

RESULTS="$PROJECT_ROOT/test-results"

mapfile -t COMPUTE_IPS < <(state_get compute_public_ips | jq -r '.[]')
if [[ -z "${COMPUTE_IPS[*]}" || "${COMPUTE_IPS[0]}" == "null" ]]; then
    mapfile -t COMPUTE_IPS < <(state_get compute_ips | jq -r '.[]')
fi
COMPUTE_COUNT=${#COMPUTE_IPS[@]}
CLUSTER=$(state_get cluster_name)

if [[ "$COMPUTE_COUNT" -lt 2 ]]; then
    die "Need at least 2 compute nodes for tests (have $COMPUTE_COUNT)"
fi

rm -rf "$RESULTS"
mkdir -p "$RESULTS"

log()  { echo "[$(date +%T)] $*"; }
pass() { echo "  PASS: $1" | tee -a "$RESULTS/summary.txt"; }
fail() { echo "  FAIL: $1" | tee -a "$RESULTS/summary.txt"; }

IP0="${COMPUTE_IPS[0]}"
IP1="${COMPUTE_IPS[1]}"

log "=== QAttach End-to-End Test Suite ==="
log "Node 0: $IP0"
log "Node 1: $IP1"
log "Mode: etcd colocated on compute nodes"
log ""

# ---- Test 1: GFS2 mounted on all nodes ----
log "=== Test 1: GFS2 mount ==="

for ip in "${COMPUTE_IPS[@]}"; do
    if $SSH_CMD "ec2-user@$ip" "mountpoint -q /mnt/shared" 2>/dev/null; then
        pass "GFS2 mounted on $ip"
    else
        fail "GFS2 NOT mounted on $ip"
    fi
done
echo

# ---- Test 2: etcd membership ----
log "=== Test 2: etcd membership ==="

MEMBER_COUNT=$($SSH_CMD "ec2-user@$IP0" \
    "sudo ETCDCTL_API=3 etcdctl \
      --endpoints=https://localhost:2379 \
      --cacert=/etc/cluster-agent/ca.crt \
      --cert=/etc/cluster-agent/client.crt \
      --key=/etc/cluster-agent/client.key \
      get cluster/members/ --prefix --keys-only" 2>/dev/null | wc -l)

if [[ "$MEMBER_COUNT" -ge "$COMPUTE_COUNT" ]]; then
    pass "etcd members: $MEMBER_COUNT (expected >= $COMPUTE_COUNT)"
else
    fail "etcd members: $MEMBER_COUNT (expected >= $COMPUTE_COUNT)"
fi
echo

# ---- Test 3: Concurrent write ----
log "=== Test 3: Concurrent file write ==="

TESTFILE="/mnt/shared/.e2e_test_$$"

$SSH_CMD "ec2-user@$IP0" "sudo bash -c 'echo \"node0-\$(date +%s)\" > $TESTFILE'" 2>/dev/null &
PID0=$!
sync
sleep 1
$SSH_CMD "ec2-user@$IP1" "sudo bash -c 'echo \"node1-\$(date +%s)\" > $TESTFILE'" 2>/dev/null &
PID1=$!
wait $PID0 $PID1 2>/dev/null
sync
sleep 1
CONTENT0=$($SSH_CMD "ec2-user@$IP0" "sudo cat $TESTFILE" 2>/dev/null || echo "MISSING")
CONTENT1=$($SSH_CMD "ec2-user@$IP1" "sudo cat $TESTFILE" 2>/dev/null || echo "MISSING")

if [[ "$CONTENT0" != "MISSING" ]] && [[ "$CONTENT1" != "MISSING" ]]; then
    pass "concurrent write: node0='$CONTENT0' node1='$CONTENT1'"
else
    fail "concurrent write failed"
fi
$SSH_CMD "ec2-user@$IP0" "sudo rm -f $TESTFILE" 2>/dev/null || true
echo

# ---- Test 4: File visible from both nodes ----
log "=== Test 4: Cross-node visibility ==="

VIS_FILE="/mnt/shared/.e2e_vis_$$"
$SSH_CMD "ec2-user@$IP0" "sudo tee $VIS_FILE <<< visible > /dev/null" 2>/dev/null
sync
sleep 1
VIS1=$($SSH_CMD "ec2-user@$IP1" "sudo cat $VIS_FILE" 2>/dev/null || echo "MISSING")

if [[ "$VIS1" == "visible" ]]; then
    pass "cross-node visibility: file written on node0 visible on node1"
else
    fail "cross-node visibility failed: got '$VIS1'"
fi
$SSH_CMD "ec2-user@$IP0" "sudo rm -f $VIS_FILE" 2>/dev/null || true
echo

# ---- Test 5: Agent restart survival ----
log "=== Test 5: Agent restart ==="

$SSH_CMD "ec2-user@$IP0" "sudo systemctl restart cluster-agent" 2>/dev/null
if wait_for_active "$IP0" "cluster-agent" 12 5; then
    pass "agent restart: active after restart"
else
    fail "agent restart: did not become active"
fi
echo

# ---- Test 6: etcd cluster health ----
log "=== Test 6: etcd cluster health ==="

ETCD_HEALTH=$($SSH_CMD "ec2-user@$IP0" \
    "sudo ETCDCTL_API=3 etcdctl \
      --endpoints=https://localhost:2379 \
      --cacert=/etc/cluster-agent/ca.crt \
      --cert=/etc/cluster-agent/client.crt \
      --key=/etc/cluster-agent/client.key \
      endpoint health --cluster" 2>/dev/null)

HEALTHY_COUNT=$(echo "$ETCD_HEALTH" | grep -c "is healthy" || echo 0)
if [[ "$HEALTHY_COUNT" -ge 1 ]]; then
    pass "etcd health: $HEALTHY_COUNT healthy endpoint(s)"
else
    fail "etcd health check failed"
fi
echo

# ---- Test 7: Lock module loaded ----
log "=== Test 7: Kernel module ==="

for ip in "${COMPUTE_IPS[@]}"; do
    if $SSH_CMD "ec2-user@$ip" "lsmod | grep -q gfs2" 2>/dev/null; then
        pass "gfs2 module loaded on $ip"
    else
        fail "gfs2 module NOT loaded on $ip"
    fi
done
echo

# ---- Summary ----
# grep -c already prints 0 when nothing matches; the old `|| echo 0`
# appended a second line and broke the arithmetic below.
PASS_COUNT=$(grep -c "^  PASS:" "$RESULTS/summary.txt" 2>/dev/null || true)
FAIL_COUNT=$(grep -c "^  FAIL:" "$RESULTS/summary.txt" 2>/dev/null || true)
PASS_COUNT=${PASS_COUNT:-0}
FAIL_COUNT=${FAIL_COUNT:-0}

log "============================================"
log "Results: $PASS_COUNT passed, $FAIL_COUNT failed"
log "Details: $RESULTS/summary.txt"
log "============================================"

exit $((FAIL_COUNT > 0 ? 1 : 0))
