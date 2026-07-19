#!/bin/bash
# run-sequential-test.sh — sequential cross-node I/O without contention.
#
# Writes on one node, reads on another, verifies edits are visible.
# Operations are spaced by a delay to avoid lock contention.
#
# Usage: ./run-sequential-test.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/state.sh"

mapfile -t COMPUTE_IPS < <(state_get compute_public_ips | jq -r '.[]')
if [[ -z "${COMPUTE_IPS[*]}" || "${COMPUTE_IPS[0]}" == "null" ]]; then
    mapfile -t COMPUTE_IPS < <(state_get compute_ips | jq -r '.[]')
fi

COMPUTE_COUNT=${#COMPUTE_IPS[@]}
if [[ "$COMPUTE_COUNT" -lt 2 ]]; then
    die "Need at least 2 compute nodes (got $COMPUTE_COUNT)"
fi

DELAY=5
TEST_DIR="/mnt/shared/seqtest"

PASS=0
FAIL=0

log() { echo "[$(date +%T)] $*"; }
pass() { PASS=$((PASS + 1)); echo "  PASS: $*"; }
fail() { FAIL=$((FAIL + 1)); echo "  FAIL: $*"; }

log "=== Sequential Cross-Node I/O Test (${COMPUTE_COUNT} nodes, ${DELAY}s delay) ==="
log ""

# ---- setup ----

log "Creating test directory..."
ssh $SSH_OPTS "ec2-user@${COMPUTE_IPS[0]}" "sudo rm -rf $TEST_DIR; sudo mkdir -p $TEST_DIR" 2>/dev/null

# ---- Test 1: write on node0, read on all others ----
log "Test 1: node0 write → all nodes read"
ssh $SSH_OPTS "ec2-user@${COMPUTE_IPS[0]}" "echo 'data-from-node0' | sudo tee $TEST_DIR/file1 > /dev/null" 2>/dev/null
sync
sleep $DELAY

for ((i=1; i<COMPUTE_COUNT; i++)); do
    ip="${COMPUTE_IPS[$i]}"
    val=$(ssh $SSH_OPTS "ec2-user@$ip" "sudo cat $TEST_DIR/file1" 2>/dev/null)
    [[ "$val" == "data-from-node0" ]] && pass "node$i read node0's write" || fail "node$i read: '$val'"
done

# ---- Test 2: each node writes its own file sequentially, all nodes read all files ----
log "Test 2: each node writes sequentially, then all nodes read all files"
for ((i=0; i<COMPUTE_COUNT; i++)); do
    ip="${COMPUTE_IPS[$i]}"
    ssh $SSH_OPTS "ec2-user@$ip" "echo 'from-node${i}' | sudo tee $TEST_DIR/node${i} > /dev/null" 2>/dev/null
    sleep 2
done
sync
sleep $DELAY

for ((i=0; i<COMPUTE_COUNT; i++)); do
    ip="${COMPUTE_IPS[$i]}"
    for ((j=0; j<COMPUTE_COUNT; j++)); do
        val=$(ssh $SSH_OPTS "ec2-user@$ip" "sudo cat $TEST_DIR/node${j}" 2>/dev/null)
        expected="from-node${j}"
        [[ "$val" == "$expected" ]] && pass "node$i sees node${j}'s file" || fail "node$i reading node${j}: got '$val' expected '$expected'"
    done
done

# ---- Test 3: append to a file from one node, verify on another ----
log "Test 3: node0 append, node1 sees appended data"
ssh $SSH_OPTS "ec2-user@${COMPUTE_IPS[0]}" "echo 'line2' | sudo tee -a $TEST_DIR/file1 > /dev/null" 2>/dev/null
sync
sleep $DELAY

val=$(ssh $SSH_OPTS "ec2-user@${COMPUTE_IPS[1]}" "sudo cat $TEST_DIR/file1" 2>/dev/null)
expected=$'data-from-node0\nline2'
[[ "$val" == "$expected" ]] && pass "node1 sees appended data" || fail "node1 read: '$val'"

# ---- Test 4: overwrite from node2, verify on node0 ----
if [[ "$COMPUTE_COUNT" -ge 3 ]]; then
    log "Test 4: node2 overwrites, node0 sees new data"
    ssh $SSH_OPTS "ec2-user@${COMPUTE_IPS[2]}" "echo 'overwritten-by-n2' | sudo tee $TEST_DIR/file1 > /dev/null" 2>/dev/null
    sync
    sleep $DELAY

    val=$(ssh $SSH_OPTS "ec2-user@${COMPUTE_IPS[0]}" "sudo cat $TEST_DIR/file1" 2>/dev/null)
    [[ "$val" == "overwritten-by-n2" ]] && pass "node0 sees node2's overwrite" || fail "node0 read: '$val'"
fi

# ---- Test 5: D-state check ----
log "Test 5: no D-state processes"
for ip in "${COMPUTE_IPS[@]}"; do
    dc=$(ssh $SSH_OPTS "ec2-user@$ip" "ps aux | awk '\$8~/D/' | grep -v gfs2_quotad | wc -l" 2>/dev/null | tr -d '[:space:]')
    [[ "${dc:-0}" -eq 0 ]] && pass "$ip: 0 D-state" || fail "$ip: ${dc} D-state processes"
done

# ---- cleanup ----
ssh $SSH_OPTS "ec2-user@${COMPUTE_IPS[0]}" "sudo rm -rf $TEST_DIR" 2>/dev/null

log ""
log "============================================"
log "$PASS passed, $FAIL failed"
log "============================================"

exit $((FAIL > 0 ? 1 : 0))