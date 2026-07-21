#!/bin/bash
# run-cross-node-test.sh — comprehensive sequential cross-node I/O.
#
# Tests directory creation, file writes, reads, appends, overwrites,
# and deletions — all sequential across 3 nodes with 3s delays to
# avoid lock contention.
#
# Usage: ./run-cross-node-test.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/state.sh"

mapfile -t IPS < <(state_get compute_public_ips | jq -r '.[]')
if [[ -z "${IPS[*]}" || "${IPS[0]}" == "null" ]]; then
    mapfile -t IPS < <(state_get compute_ips | jq -r '.[]')
fi
[[ "${#IPS[@]}" -ge 2 ]] || die "Need at least 2 compute nodes (got ${#IPS[@]})"

N0="${IPS[0]}"; N1="${IPS[1]}"; N2="${IPS[2]}"
TEST="/mnt/shared/crosstest"
DELAY=3

PASS=0; FAIL=0
log() { echo "[$(date +%T)] $*"; }
pass() { PASS=$((PASS+1)); echo "  PASS: $*"; }
fail() { FAIL=$((FAIL+1)); echo "  FAIL: $*"; }

# ---- setup ----
log "=== Setup ==="
ssh $SSH_OPTS "ec2-user@$N0" "sudo rm -rf $TEST; sudo mkdir -p $TEST" 2>/dev/null
sleep $DELAY

# ---- Test 1: create subfolders from node0, verify on all nodes ----
log "=== Test 1: create subfolders ==="
ssh $SSH_OPTS "ec2-user@$N0" "sudo mkdir -p $TEST/dirA $TEST/dirB $TEST/dirA/sub1" 2>/dev/null
sync; sleep $DELAY
for ip in $N0 $N1 $N2; do
    for d in dirA dirB dirA/sub1; do
        ssh $SSH_OPTS "ec2-user@$ip" "sudo test -d $TEST/$d" 2>/dev/null \
            && pass "$(echo $ip | cut -d. -f1) sees $TEST/$d" \
            || fail "$(echo $ip | cut -d. -f1) missing $TEST/$d"
    done
done

# ---- Test 2: create files on node0, verify on all nodes ----
log "=== Test 2: create files ==="
ssh $SSH_OPTS "ec2-user@$N0" "echo 'base-file' | sudo tee $TEST/dirA/file_a1 > /dev/null" 2>/dev/null
ssh $SSH_OPTS "ec2-user@$N0" "echo 'base-file' | sudo tee $TEST/dirB/file_b1 > /dev/null" 2>/dev/null
sync; sleep $DELAY
for ip in $N0 $N1 $N2; do
    r=$(ssh $SSH_OPTS "ec2-user@$ip" "sudo cat $TEST/dirA/file_a1" 2>/dev/null)
    [[ "$r" == "base-file" ]] && pass "$(echo $ip | cut -d. -f1) reads file_a1" || fail "$(echo $ip | cut -d. -f1) file_a1: '$r'"
done

# ---- Test 3: node1 writes to existing file, node0 and node2 see it ----
log "=== Test 3: cross-node write to existing file ==="
ssh $SSH_OPTS "ec2-user@$N1" "echo 'edited-by-n1' | sudo tee $TEST/dirA/file_a1 > /dev/null" 2>/dev/null
sync; sleep $DELAY
for ip in $N0 $N2; do
    r=$(ssh $SSH_OPTS "ec2-user@$ip" "sudo cat $TEST/dirA/file_a1" 2>/dev/null)
    [[ "$r" == "edited-by-n1" ]] && pass "$(echo $ip | cut -d. -f1) sees n1's edit" || fail "$(echo $ip | cut -d. -f1) saw '$r'"
done

# ---- Test 4: node2 creates a new file in a subfolder, all see it ----
log "=== Test 4: create file from another node ==="
ssh $SSH_OPTS "ec2-user@$N2" "echo 'from-n2' | sudo tee $TEST/dirA/sub1/file_s1 > /dev/null" 2>/dev/null
sync; sleep $DELAY
for ip in $N0 $N1; do
    r=$(ssh $SSH_OPTS "ec2-user@$ip" "sudo cat $TEST/dirA/sub1/file_s1" 2>/dev/null)
    [[ "$r" == "from-n2" ]] && pass "$(echo $ip | cut -d. -f1) sees n2's file" || fail "$(echo $ip | cut -d. -f1) saw '$r'"
done

# ---- Test 5: append from node0, read from node1 ----
log "=== Test 5: append ==="
ssh $SSH_OPTS "ec2-user@$N0" "echo 'appended-line' | sudo tee -a $TEST/dirB/file_b1 > /dev/null" 2>/dev/null
sync; sleep $DELAY
r=$(ssh $SSH_OPTS "ec2-user@$N1" "sudo cat $TEST/dirB/file_b1" 2>/dev/null)
expected=$'base-file\nappended-line'
[[ "$r" == "$expected" ]] && pass "n1 sees appended data" || fail "n1 saw: '$r'"

# ---- Test 6: delete a file from node1, verify gone on node0 and node2 ----
log "=== Test 6: delete file ==="
ssh $SSH_OPTS "ec2-user@$N1" "sudo rm -f $TEST/dirA/file_a1" 2>/dev/null
sync; sleep $DELAY
for ip in $N0 $N2; do
    ssh $SSH_OPTS "ec2-user@$ip" "sudo test -f $TEST/dirA/file_a1" 2>/dev/null \
        && fail "$(echo $ip | cut -d. -f1) still sees deleted file" \
        || pass "$(echo $ip | cut -d. -f1) file deleted"
done

# ---- Test 7: delete a subdirectory (must be empty) and verify ----
log "=== Test 7: delete subdirectory ==="
ssh $SSH_OPTS "ec2-user@$N2" "sudo rm -f $TEST/dirA/sub1/file_s1" 2>/dev/null
ssh $SSH_OPTS "ec2-user@$N2" "sudo rmdir $TEST/dirA/sub1" 2>/dev/null
sync; sleep $DELAY
for ip in $N0 $N1; do
    ssh $SSH_OPTS "ec2-user@$ip" "sudo test -d $TEST/dirA/sub1" 2>/dev/null \
        && fail "$(echo $ip | cut -d. -f1) still sees deleted dir" \
        || pass "$(echo $ip | cut -d. -f1) dir deleted"
done

# ---- Test 8: directory listing matches across all nodes ----
log "=== Test 8: directory listing consistency ==="
L0=$(ssh $SSH_OPTS "ec2-user@$N0" "sudo ls -1 $TEST/dirA/ 2>/dev/null" 2>/dev/null)
L1=$(ssh $SSH_OPTS "ec2-user@$N1" "sudo ls -1 $TEST/dirA/ 2>/dev/null" 2>/dev/null)
L2=$(ssh $SSH_OPTS "ec2-user@$N2" "sudo ls -1 $TEST/dirA/ 2>/dev/null" 2>/dev/null)
[[ "$L0" == "$L1" && "$L1" == "$L2" ]] && pass "all 3 nodes see same listing" || fail "mismatch: n0='$L0' n1='$L1' n2='$L2'"

# ---- Test 9: D-state check ----
log "=== Test 9: D-state ==="
for ip in $N0 $N1 $N2; do
    dc=$(ssh $SSH_OPTS "ec2-user@$ip" "ps aux | awk '\$8~/D/ && !/gfs2_quotad/' | wc -l" 2>/dev/null | tr -d '[:space:]')
    [[ "${dc:-0}" -eq 0 ]] && pass "$(echo $ip | cut -d. -f1): 0 D-state" || fail "$(echo $ip | cut -d. -f1): ${dc} D-state"
done

# ---- Test 10: GFS2 health ----
log "=== Test 10: GFS2 withdraw ==="
for ip in $N0 $N1 $N2; do
    wd=$(ssh $SSH_OPTS "ec2-user@$ip" "sudo dmesg | grep -c withdraw" 2>/dev/null | tr -d '[:space:]')
    [[ "${wd:-0}" -eq 0 ]] && pass "$(echo $ip | cut -d. -f1): 0 withdraws" || fail "$(echo $ip | cut -d. -f1): ${wd} withdraws"
done

# ---- cleanup ----
ssh $SSH_OPTS "ec2-user@$N0" "sudo rm -rf $TEST" 2>/dev/null

log ""
log "============================================"
log "$PASS passed, $FAIL failed"
log "============================================"
exit $((FAIL > 0 ? 1 : 0))