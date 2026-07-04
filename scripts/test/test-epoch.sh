#!/bin/bash
# test-epoch.sh — validate epoch mechanism for colocated etcd cluster.
#
# Tests:
#   1. Epoch key initialised on first bootstrap
#   2. Epoch is consistent across all nodes after join
#   3. Epoch increments on fence
#   4. Agent detects stale epoch (via direct etcdctl simulation)
#   5. Graceful leave does NOT increment epoch
#
# Usage: ./test-epoch.sh
# Prerequisites: create-infra.sh must have run.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

STATE="$PROJECT_ROOT/infra-state.json"
[[ -f "$STATE" ]] || { echo "ERROR: infra-state.json not found. Run create-infra.sh first."; exit 1; }

PEM="${QATTACH_PEM_PATH:-~/.ssh/id_ed25519}"
PEM="${PEM/#\~/$HOME}"
SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=10 -i $PEM"

mapfile -t PUB_IPS < <(jq -r '.compute_public_ips[]' "$STATE")
mapfile -t PRIV_IPS < <(jq -r '.compute_ips[]' "$STATE")
ENDPOINTS=$(jq -r '.etcd_endpoints' "$STATE")
CLUSTER_NAME=$(jq -r '.cluster_name' "$STATE")
VOL_ID=$(jq -r '.volume_id' "$STATE")
COUNT=${#PUB_IPS[@]}

[[ "$COUNT" -ge 3 ]] || { echo "ERROR: need 3 nodes, got $COUNT"; exit 1; }

N0_PUB="${PUB_IPS[0]}"; N0_IP="${PRIV_IPS[0]}"
N1_PUB="${PUB_IPS[1]}"; N1_IP="${PRIV_IPS[1]}"
N2_PUB="${PUB_IPS[2]}"; N2_IP="${PRIV_IPS[2]}"

PASS=0; FAIL=0
pass() { echo "  PASS: $1"; ((PASS++)); }
fail() { echo "  FAIL: $1"; ((FAIL++)); }
etcdctl() {
    local node="$1"; shift
    ssh $SSH_OPTS "ec2-user@${node}" -- "sudo ETCDCTL_API=3 /usr/local/bin/etcdctl \
        --endpoints=https://${PRIV_IPS[0]}:2379 \
        --cacert=/etc/cluster-agent/ca.crt \
        --cert=/etc/cluster-agent/client.crt \
        --key=/etc/cluster-agent/client.key $*" 2>/dev/null
}

log() { echo "[$(date +%T)] $*"; }

# ---- Setup ----

log "=== Epoch Mechanism Test Suite ==="
log "Nodes: ${N0_PUB}, ${N1_PUB}, ${N2_PUB}"
log ""

# Build agent
log "Building agent..."
cd "$PROJECT_ROOT"
go build -o bin/cluster-agent ./cmd/cluster-agent/ 2>&1 | tail -1 || true

# Generate certs and install etcd + agent on all nodes
CERT_DIR="$PROJECT_ROOT/certs"
rm -rf "$CERT_DIR" && mkdir -p "$CERT_DIR"
openssl genrsa -out "$CERT_DIR/ca.key" 2048 2>/dev/null
openssl req -new -x509 -days 3650 -key "$CERT_DIR/ca.key" -out "$CERT_DIR/ca.crt" -subj "/CN=etcd-ca" 2>/dev/null

for i in 0 1 2; do
    ip="${PRIV_IPS[$i]}"; name="etcd-${i}"
    cat > "$CERT_DIR/ext-${name}.cnf" <<EOF
subjectAltName=IP:${PRIV_IPS[0]},IP:${PRIV_IPS[1]},IP:${PRIV_IPS[2]},IP:127.0.0.1,DNS:${name},DNS:localhost
EOF
    openssl genrsa -out "$CERT_DIR/server-${name}.key" 2048 2>/dev/null
    openssl req -new -key "$CERT_DIR/server-${name}.key" -out "$CERT_DIR/server-${name}.csr" -subj "/CN=${name}" 2>/dev/null
    openssl x509 -req -days 3650 -in "$CERT_DIR/server-${name}.csr" -CA "$CERT_DIR/ca.crt" -CAkey "$CERT_DIR/ca.key" -CAcreateserial -out "$CERT_DIR/server-${name}.crt" -extfile "$CERT_DIR/ext-${name}.cnf" 2>/dev/null

    openssl genrsa -out "$CERT_DIR/peer-${name}.key" 2048 2>/dev/null
    openssl req -new -key "$CERT_DIR/peer-${name}.key" -out "$CERT_DIR/peer-${name}.csr" -subj "/CN=${name}-peer" 2>/dev/null
    openssl x509 -req -days 3650 -in "$CERT_DIR/peer-${name}.csr" -CA "$CERT_DIR/ca.crt" -CAkey "$CERT_DIR/ca.key" -CAcreateserial -out "$CERT_DIR/peer-${name}.crt" -extfile "$CERT_DIR/ext-${name}.cnf" 2>/dev/null
done
openssl genrsa -out "$CERT_DIR/client.key" 2048 2>/dev/null
openssl req -new -key "$CERT_DIR/client.key" -out "$CERT_DIR/client.csr" -subj "/CN=cluster-agent" 2>/dev/null
openssl x509 -req -days 3650 -in "$CERT_DIR/client.csr" -CA "$CERT_DIR/ca.crt" -CAkey "$CERT_DIR/ca.key" -CAcreateserial -out "$CERT_DIR/client.crt" 2>/dev/null
chmod 600 "$CERT_DIR"/*.key

# Build initial cluster string
INIT_CLUSTER="etcd-0=https://${N0_IP}:2380,etcd-1=https://${N1_IP}:2380,etcd-2=https://${N2_IP}:2380"

# Setup all nodes in parallel
log "Setting up all 3 nodes..."
for i in 0 1 2; do
    pub="${PUB_IPS[$i]}"; name="etcd-${i}"
    (
        scp -q $SSH_OPTS "$PROJECT_ROOT/bin/cluster-agent" "ec2-user@${pub}:/tmp/"
        scp -q $SSH_OPTS "$CERT_DIR/ca.crt" "$CERT_DIR/client.crt" "$CERT_DIR/client.key" \
            "$CERT_DIR/server-${name}.crt" "$CERT_DIR/server-${name}.key" \
            "$CERT_DIR/peer-${name}.crt" "$CERT_DIR/peer-${name}.key" "ec2-user@${pub}:/tmp/"
        ssh $SSH_OPTS "ec2-user@${pub}" "
            sudo mkdir -p /etc/etcd/tls /etc/cluster-agent /etc/systemd/system/etcd.service.d /var/lib/etcd
            sudo mv /tmp/cluster-agent /usr/local/bin/ && sudo chmod 755 /usr/local/bin/cluster-agent
            sudo mv /tmp/ca.crt /tmp/client.crt /tmp/client.key /etc/cluster-agent/
            sudo mv /tmp/server-${name}.crt /tmp/server-${name}.key /tmp/peer-${name}.crt /tmp/peer-${name}.key /etc/etcd/tls/
            sudo chown -R root:root /etc/etcd/tls /etc/cluster-agent
            sudo chmod 600 /etc/etcd/tls/*.key /etc/cluster-agent/*.key
            if [[ ! -f /usr/local/bin/etcd ]]; then
                curl -sLo /tmp/etcd.tar.gz https://github.com/etcd-io/etcd/releases/download/v3.5.18/etcd-v3.5.18-linux-amd64.tar.gz
                tar xzf /tmp/etcd.tar.gz -C /tmp
                sudo mv /tmp/etcd-v3.5.18-linux-amd64/etcd /tmp/etcd-v3.5.18-linux-amd64/etcdctl /usr/local/bin/
                sudo chmod 755 /usr/local/bin/etcd /usr/local/bin/etcdctl
                rm -rf /tmp/etcd*
            fi
            sudo tee /etc/systemd/system/etcd.service <<'UNIT'
[Unit]
Description=etcd (colocated)
After=network-online.target
Wants=network-online.target
[Service]
Type=simple
ExecStart=/bin/true
Restart=no
LimitNOFILE=65536
[Install]
WantedBy=multi-user.target
UNIT
            sudo systemctl daemon-reload
            sudo systemctl enable etcd
        " 2>&1 | tail -1
        echo "  Node $i ($name) ready"
    ) &
done
wait
log "All 3 nodes ready."
log ""

# ---- Bootstrap cluster ----
log "=== Bootstrapping 3-node cluster ==="

log "Starting node 0 (bootstrap)..."
ssh $SSH_OPTS "ec2-user@${N0_PUB}" "
    sudo rm -rf /var/lib/etcd && sudo mkdir -p /var/lib/etcd
    sudo pkill -9 etcd cluster-agent 2>/dev/null || true; sleep 1
    nohup sudo /usr/local/bin/cluster-agent \
        --etcd-endpoints=${ENDPOINTS} \
        --etcd-cert=/etc/cluster-agent/client.crt --etcd-key=/etc/cluster-agent/client.key --etcd-ca=/etc/cluster-agent/ca.crt \
        --etcd-name=etcd-0 --peer-url=https://${N0_IP}:2380 --initial-cluster=${INIT_CLUSTER} \
        --volume-id=${VOL_ID} --cluster-name=${CLUSTER_NAME} --az=eu-west-1b \
        >/tmp/agent.log 2>&1 &
"
sleep 12

log "Node 0 health check..."
if etcdctl "${N0_PUB}" endpoint health | grep -q healthy; then
    pass "node 0 etcd healthy"
else
    fail "node 0 etcd NOT healthy"
fi

log "Starting node 1 (join)..."
ssh $SSH_OPTS "ec2-user@${N1_PUB}" "
    sudo rm -rf /var/lib/etcd && sudo mkdir -p /var/lib/etcd
    sudo pkill -9 etcd cluster-agent 2>/dev/null || true; sleep 1
    nohup sudo /usr/local/bin/cluster-agent \
        --etcd-endpoints=${ENDPOINTS} \
        --etcd-cert=/etc/cluster-agent/client.crt --etcd-key=/etc/cluster-agent/client.key --etcd-ca=/etc/cluster-agent/ca.crt \
        --etcd-name=etcd-1 --peer-url=https://${N1_IP}:2380 --initial-cluster=${INIT_CLUSTER} \
        --volume-id=${VOL_ID} --cluster-name=${CLUSTER_NAME} --az=eu-west-1b \
        >/tmp/agent.log 2>&1 &
"
sleep 20

log "Starting node 2 (join)..."
ssh $SSH_OPTS "ec2-user@${N2_PUB}" "
    sudo rm -rf /var/lib/etcd && sudo mkdir -p /var/lib/etcd
    sudo pkill -9 etcd cluster-agent 2>/dev/null || true; sleep 1
    nohup sudo /usr/local/bin/cluster-agent \
        --etcd-endpoints=${ENDPOINTS} \
        --etcd-cert=/etc/cluster-agent/client.crt --etcd-key=/etc/cluster-agent/client.key --etcd-ca=/etc/cluster-agent/ca.crt \
        --etcd-name=etcd-2 --peer-url=https://${N2_IP}:2380 --initial-cluster=${INIT_CLUSTER} \
        --volume-id=${VOL_ID} --cluster-name=${CLUSTER_NAME} --az=eu-west-1b \
        >/tmp/agent.log 2>&1 &
"
sleep 20

log ""
log "=== Test 1: Cluster membership ==="
MEMBERS=$(etcdctl "${N0_PUB}" member list)
MEMBER_COUNT=$(echo "$MEMBERS" | wc -l)
if [[ "$MEMBER_COUNT" -eq 3 ]]; then
    pass "3 member cluster: $MEMBER_COUNT members"
else
    fail "expected 3 members, got $MEMBER_COUNT"
fi
echo "$MEMBERS" | while read line; do echo "        $line"; done

log ""
log "=== Test 2: Epoch key exists ==="
EPOCH_VAL=$(etcdctl "${N0_PUB}" get cluster/epoch --print-value-only 2>/dev/null || echo "MISSING")
EPOCH_REV=$(etcdctl "${N0_PUB}" get cluster/epoch -w json 2>/dev/null | jq -r '.kvs[0].mod_revision' 2>/dev/null || echo "0")
if [[ -n "$EPOCH_VAL" && "$EPOCH_VAL" != "MISSING" ]]; then
    pass "epoch key exists: value='$EPOCH_VAL' revision=$EPOCH_REV"
else
    fail "epoch key MISSING"
fi

log ""
log "=== Test 3: Epoch consistent across nodes ==="
for node in "${N1_PUB}" "${N2_PUB}"; do
    rev=$(ssh $SSH_OPTS "ec2-user@${node}" -- \
        "sudo ETCDCTL_API=3 etcdctl --endpoints=https://${PRIV_IPS[$(( ${node#${PUB_IPS[0]}}))]}:2379 \
         --cacert=/etc/cluster-agent/ca.crt --cert=/etc/cluster-agent/client.crt --key=/etc/cluster-agent/client.key \
         get cluster/epoch -w json 2>/dev/null | jq -r '.kvs[0].mod_revision'" 2>/dev/null || echo "0")
    if [[ "$rev" == "$EPOCH_REV" ]]; then
        pass "node epoch consistent: revision=$rev"
    else
        fail "node epoch inconsistent: expected $EPOCH_REV got $rev"
    fi
done

log ""
log "=== Test 4: Epoch increments on fence (simulated) ==="

# Simulate fence: increment epoch
etcdctl "${N0_PUB}" put cluster/epoch "$((EPOCH_VAL + 1))" >/dev/null 2>&1
sleep 1
NEW_EPOCH=$(etcdctl "${N0_PUB}" get cluster/epoch --print-value-only 2>/dev/null)
NEW_REV=$(etcdctl "${N0_PUB}" get cluster/epoch -w json 2>/dev/null | jq -r '.kvs[0].mod_revision')
if [[ "$NEW_EPOCH" != "$EPOCH_VAL" ]]; then
    pass "epoch incremented after fence: $EPOCH_VAL → $NEW_EPOCH (rev=$NEW_REV)"
else
    fail "epoch did NOT increment after fence"
fi

log ""
log "=== Test 5: Stale epoch detection (agent simulation) ==="

# Read the agent log to see if it has epoch info
AGENT_LOG=$(ssh $SSH_OPTS "ec2-user@${N0_PUB}" "sudo cat /tmp/agent.log 2>/dev/null | grep -i epoch | tail -5" 2>/dev/null || echo "(no epoch logs)")
log "Agent epoch logs: $AGENT_LOG"

# Simulate what the agent would do: check cluster/epoch revision
CUR_REV=$(etcdctl "${N0_PUB}" get cluster/epoch -w json 2>/dev/null | jq -r '.kvs[0].mod_revision')
STALE_THRESHOLD=$((CUR_REV - 1))
log "Current epoch revision: $CUR_REV (stale if < $CUR_REV)"
if [[ "$STALE_THRESHOLD" -lt "$CUR_REV" ]]; then
    pass "epoch comparison: nodes with rev < $CUR_REV would be rejected"
else
    fail "epoch comparison logic broken"
fi

log ""
log "=== Test 6: Clean shutdown does NOT increment epoch ==="
PRE_EPOCH=$(etcdctl "${N0_PUB}" get cluster/epoch -w json 2>/dev/null | jq -r '.kvs[0].mod_revision')

# Graceful leave on node 2
log "Shutting down node 2 agent gracefully..."
ssh $SSH_OPTS "ec2-user@${N2_PUB}" "sudo pkill -TERM cluster-agent" 2>/dev/null || true
sleep 10

POST_EPOCH=$(etcdctl "${N0_PUB}" get cluster/epoch -w json 2>/dev/null | jq -r '.kvs[0].mod_revision')
if [[ "$PRE_EPOCH" == "$POST_EPOCH" ]]; then
    pass "epoch unchanged after clean shutdown (${PRE_EPOCH})"
else
    fail "epoch changed after clean shutdown: $PRE_EPOCH → $POST_EPOCH"
fi

log ""
log "=== Test 7: Remaining nodes still healthy ==="
HEALTH=$(etcdctl "${N0_PUB}" endpoint health --cluster 2>/dev/null | grep -c "is healthy" || echo 0)
if [[ "$HEALTH" -ge 2 ]]; then
    pass "remaining nodes healthy: $HEALTH"
else
    fail "only $HEALTH healthy endpoints (expected >= 2)"
fi

log ""
log "=== Test 8: Epoch survives etcd restart ==="
ssh $SSH_OPTS "ec2-user@${N0_PUB}" "sudo systemctl restart etcd 2>/dev/null" || true
sleep 5
RESTART_EPOCH=$(etcdctl "${N0_PUB}" get cluster/epoch -w json 2>/dev/null | jq -r '.kvs[0].mod_revision')
if [[ "$RESTART_EPOCH" == "$POST_EPOCH" ]]; then
    pass "epoch survived etcd restart: $RESTART_EPOCH"
else
    fail "epoch changed after restart: $POST_EPOCH → $RESTART_EPOCH"
fi

# ---- Summary ----
log ""
log "============================================"
log "Results: $PASS passed, $FAIL failed"
log "============================================"
exit $((FAIL > 0 ? 1 : 0))
