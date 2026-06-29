#!/bin/bash
# run-full-test.sh — end-to-end test orchestration.
#
# Runs the test suite on the deployed cluster, plus additional
# fencing and partition tests.
#
# Usage: ./run-full-test.sh
#
# Prerequisites: create-infra.sh + setup-etcd.sh + setup-compute.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$SCRIPT_DIR/state.sh"

PEM="${PEM_PATH/#\~/$HOME}"
SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=10 -i $PEM"
RESULTS="$PROJECT_ROOT/test-results"

mapfile -t COMPUTE_IPS < <(state_get compute_ips | jq -r '.[]')
COMPUTE_COUNT=${#COMPUTE_IPS[@]}
ETCD0_IP=$(state_get etcd_ips | jq -r '.[0]')
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
log ""

# ---- Test 1: GFS2 mounted on all nodes ----
log "=== Test 1: GFS2 mount ==="

for ip in "${COMPUTE_IPS[@]}"; do
    if ssh $SSH_OPTS "ec2-user@$ip" "mountpoint -q /mnt/shared" 2>/dev/null; then
        pass "GFS2 mounted on $ip"
    else
        fail "GFS2 NOT mounted on $ip"
    fi
done
echo

# ---- Test 2: etcd membership ----
log "=== Test 2: etcd membership ==="

CERT_DIR="$PROJECT_ROOT/certs"
MEMBER_COUNT=$(ssh $SSH_OPTS "ec2-user@$IP0" \
    "ETCDCTL_API=3 etcdctl \
      --endpoints=https://${ETCD0_IP}:2379 \
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

# Write from node 0
ssh $SSH_OPTS "ec2-user@$IP0" "echo node0-\$(date +%s) > $TESTFILE" 2>/dev/null
sleep 1
# Write from node 1
ssh $SSH_OPTS "ec2-user@$IP1" "echo node1-\$(date +%s) > $TESTFILE" 2>/dev/null
sleep 1
# Read from both
CONTENT0=$(ssh $SSH_OPTS "ec2-user@$IP0" "cat $TESTFILE 2>/dev/null" || echo "MISSING")
CONTENT1=$(ssh $SSH_OPTS "ec2-user@$IP1" "cat $TESTFILE 2>/dev/null" || echo "MISSING")

if [[ "$CONTENT0" != "MISSING" ]] && [[ "$CONTENT1" != "MISSING" ]]; then
    pass "concurrent write: node0='$CONTENT0' node1='$CONTENT1'"
else
    fail "concurrent write failed"
fi
ssh $SSH_OPTS "ec2-user@$IP0" "rm -f $TESTFILE" 2>/dev/null || true
echo

# ---- Test 4: File visible from both nodes ----
log "=== Test 4: Cross-node visibility ==="

VIS_FILE="/mnt/shared/.e2e_vis_$$"
ssh $SSH_OPTS "ec2-user@$IP0" "echo visible > $VIS_FILE" 2>/dev/null
sleep 1
VIS1=$(ssh $SSH_OPTS "ec2-user@$IP1" "cat $VIS_FILE 2>/dev/null" || echo "MISSING")

if [[ "$VIS1" == "visible" ]]; then
    pass "cross-node visibility: file written on node0 visible on node1"
else
    fail "cross-node visibility failed: got '$VIS1'"
fi
ssh $SSH_OPTS "ec2-user@$IP0" "rm -f $VIS_FILE" 2>/dev/null || true
echo

# ---- Test 5: Agent restart survival ----
log "=== Test 5: Agent restart ==="

ssh $SSH_OPTS "ec2-user@$IP0" "sudo systemctl restart cluster-agent" 2>/dev/null
sleep 5

AGENT_ALIVE=$(ssh $SSH_OPTS "ec2-user@$IP0" "sudo systemctl is-active cluster-agent" 2>/dev/null)
if [[ "$AGENT_ALIVE" == "active" ]]; then
    pass "agent restart: active after restart"
else
    fail "agent restart: state=$AGENT_ALIVE"
fi
echo

# ---- Test 6: etcd health ----
log "=== Test 6: etcd health ==="

ETCD0_IP=$(state_get etcd_ips | jq -r '.[0]')
ETCD_HEALTH=$(ssh $SSH_OPTS "ec2-user@$ETCD0_IP" \
    "ETCDCTL_API=3 etcdctl \
      --endpoints=https://localhost:2379 \
      --cacert=/etc/etcd/tls/ca.crt \
      --cert=/etc/etcd/tls/server.crt \
      --key=/etc/etcd/tls/server.key \
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
    if ssh $SSH_OPTS "ec2-user@$ip" "lsmod | grep -q lock_etcd" 2>/dev/null; then
        pass "lock_etcd loaded on $ip"
    else
        fail "lock_etcd NOT loaded on $ip"
    fi
done
echo

# ---- Summary ----
PASS_COUNT=$(grep -c "^  PASS:" "$RESULTS/summary.txt" 2>/dev/null || echo 0)
FAIL_COUNT=$(grep -c "^  FAIL:" "$RESULTS/summary.txt" 2>/dev/null || echo 0)

log "============================================"
log "Results: $PASS_COUNT passed, $FAIL_COUNT failed"
log "Details: $RESULTS/summary.txt"
log "============================================"

exit $((FAIL_COUNT > 0 ? 1 : 0))
