#!/bin/bash
# run-add-remove-test.sh — end-to-end node add/remove test.
# 1. Baseline 3-node I/O
# 2. Add 4th node
# 3. Verify 4-node I/O
# 4. Remove 4th node
# 5. Verify 3-node I/O continues

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/state.sh"

mapfile -t IPS < <(state_get compute_public_ips | jq -r '.[]')
[[ "${#IPS[@]}" -ge 3 ]] || die "Need at least 3 nodes"

N0="${IPS[0]}"; N1="${IPS[1]}"; N2="${IPS[2]}"
T="/mnt/shared/adrtest"; DELAY=5; PASS=0; FAIL=0
log() { echo "[$(date +%T)] $*"; }
pass() { PASS=$((PASS+1)); echo "  PASS: $*"; }
fail() { FAIL=$((FAIL+1)); echo "  FAIL: $*"; }

# ---- Helpers ----
prep() {
    ssh $SSH_OPTS "ec2-user@${N0}" "sudo rm -rf $T; sudo mkdir -p $T; for f in a b c d; do echo init|sudo tee $T/\$f>/dev/null; done" 2>/dev/null
    sleep $DELAY
}
check3() {
    local label="$1"
    for ip in $N0 $N1 $N2; do
        for f in a b c; do
            r=$(ssh $SSH_OPTS "ec2-user@$ip" "sudo timeout 10 cat $T/$f" 2>/dev/null)
            local ipshort="${ip%%.*}"
            [[ "$r" == "init" ]] && pass "$label: $ipshort reads $f" || fail "$label: $ipshort read $f: '$r'"
        done
    done
}

log "=== Phase 1: Baseline 3-node I/O ==="
prep; check3 "baseline"

log "=== Phase 2: Add 4th node ==="
$SCRIPT_DIR/add-compute-node.sh 2>&1 | tail -3
mapfile -t ALL_IPS < <(state_get compute_public_ips | jq -r '.[]')
N3="${ALL_IPS[3]}"
log "  New node: $N3"

# Verify 4-node I/O
ssh $SSH_OPTS "ec2-user@$N3" "echo from-n4 | sudo timeout 10 tee $T/d >/dev/null" 2>/dev/null && echo "N4 wrote"
sleep $DELAY
r=$(ssh $SSH_OPTS "ec2-user@$N0" "sudo timeout 10 cat $T/d" 2>/dev/null); [[ "$r" == "from-n4" ]] && pass "add: N0 sees N4 file" || fail "add: N0 read '$r'"
r=$(ssh $SSH_OPTS "ec2-user@$N3" "sudo timeout 10 cat $T/a" 2>/dev/null); [[ "$r" == "init" ]] && pass "add: N4 reads existing file" || fail "add: N4 read '$r'"

# etcd members
MEM=$(ssh $SSH_OPTS "ec2-user@$N0" "
    sudo ETCDCTL_API=3 etcdctl --endpoints=https://localhost:2379 \
        --cacert=/etc/cluster-agent/ca.crt --cert=/etc/cluster-agent/client.crt \
        --key=/etc/cluster-agent/client.key member list 2>/dev/null | wc -l
" 2>/dev/null | tr -d '[:space:]')
[[ "$MEM" -eq 4 ]] && pass "add: 4 etcd members" || fail "add: $MEM members"

log "=== Phase 3: Remove 4th node ==="
N3_INSTANCE=$(state_get compute_instance_ids | jq -r '.[3]')
ssh $SSH_OPTS "ec2-user@$N3" "sudo systemctl stop cluster-agent; sudo umount /mnt/shared 2>/dev/null || true" 2>/dev/null
sleep 5
ssh $SSH_OPTS "ec2-user@$N0" "
    MEMID=\$(sudo ETCDCTL_API=3 etcdctl --endpoints=https://localhost:2379 \
        --cacert=/etc/cluster-agent/ca.crt --cert=/etc/cluster-agent/client.crt \
        --key=/etc/cluster-agent/client.key member list 2>/dev/null | grep $N3_INSTANCE | head -1 | cut -d, -f1)
    if [[ -n \"\$MEMID\" ]]; then
        sudo ETCDCTL_API=3 etcdctl --endpoints=https://localhost:2379 \
            --cacert=/etc/cluster-agent/ca.crt --cert=/etc/cluster-agent/client.crt \
            --key=/etc/cluster-agent/client.key member remove \$MEMID 2>/dev/null
        echo \"removed etcd member \$MEMID\"
    fi
" 2>/dev/null
aws ec2 terminate-instances --instance-ids "$N3_INSTANCE" --region eu-west-1 2>/dev/null
sleep 15

log "=== Phase 4: Verify 3-node continues ==="
prep
r=$(ssh $SSH_OPTS "ec2-user@$N0" "sudo timeout 10 cat $T/a" 2>/dev/null); [[ "$r" == "init" ]] && pass "remove: N0 still OK" || fail "remove: N0: '$r'"
r=$(ssh $SSH_OPTS "ec2-user@$N1" "sudo timeout 10 cat $T/b" 2>/dev/null); [[ "$r" == "init" ]] && pass "remove: N1 still OK" || fail "remove: N1: '$r'"
r=$(ssh $SSH_OPTS "ec2-user@$N2" "sudo timeout 10 cat $T/c" 2>/dev/null); [[ "$r" == "init" ]] && pass "remove: N2 still OK" || fail "remove: N2: '$r'"

MEM=$(ssh $SSH_OPTS "ec2-user@$N0" "
    sudo ETCDCTL_API=3 etcdctl --endpoints=https://localhost:2379 \
        --cacert=/etc/cluster-agent/ca.crt --cert=/etc/cluster-agent/client.crt \
        --key=/etc/cluster-agent/client.key member list 2>/dev/null | wc -l
" 2>/dev/null | tr -d '[:space:]')
[[ "$MEM" -eq 3 ]] && pass "remove: back to 3 members" || fail "remove: $MEM members"

ssh $SSH_OPTS "ec2-user@$N0" "sudo rm -rf $T" 2>/dev/null
log "=== $PASS passed, $FAIL failed ==="
exit $((FAIL > 0 ? 1 : 0))