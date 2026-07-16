#!/bin/bash
# setup-compute.sh — install etcd + cluster-agent + lock_etcd + GFS2 on compute nodes.
#
# Etcd is colocated on each compute node (no dedicated etcd instances).
# For each compute node:
#   1. Install etcd binary + etcd systemd unit
#   2. Generate mTLS certs (compute IPs as SANs)
#   3. Install kernel headers + build tools
#   4. Install cluster-agent (Go daemon) — but DO NOT start yet
#   5. First node: start agent, wait for full readiness, format GFS2, mount
#   6. Other nodes: start agent, wait for full readiness, mount GFS2
#
# Agents start sequentially — each waits for full readiness before the
# next node's agent is started. This prevents races during etcd bootstrap.
#
# Idempotent: safe to re-run. Skips already-completed steps.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$SCRIPT_DIR/state.sh"

mapfile -t COMPUTE_IPS < <(state_get compute_public_ips | jq -r '.[]')
if [[ -z "${COMPUTE_IPS[*]}" || "${COMPUTE_IPS[0]}" == "null" ]]; then
    mapfile -t COMPUTE_IPS < <(state_get compute_ips | jq -r '.[]')
fi
mapfile -t COMPUTE_PRIV_IPS < <(state_get compute_ips | jq -r '.[]')
COMPUTE_COUNT=${#COMPUTE_IPS[@]}

if [[ "$COMPUTE_COUNT" -eq 0 ]]; then
    die "No compute IPs in state file."
fi

ETCD_ENDPOINTS=$(state_get etcd_endpoints)
if [[ -z "$ETCD_ENDPOINTS" || "$ETCD_ENDPOINTS" == "null" ]]; then
    die "etcd endpoints not found in state."
fi

VOL_ID=$(state_get volume_id)
CLUSTER=$(state_get cluster_name)
CERT_DIR="$PROJECT_ROOT/certs"
ETCD_VER="v3.5.18"
ETCD_URL="https://github.com/etcd-io/etcd/releases/download/${ETCD_VER}/etcd-${ETCD_VER}-linux-amd64.tar.gz"

log "=== Compute node setup ($COMPUTE_COUNT nodes, etcd colocated) ==="
log "etcd:        $ETCD_ENDPOINTS"
log "Volume:      $VOL_ID"
log "Cluster:     $CLUSTER"
log ""

# ---- Helper: detect EBS device on a node ----

detect_ebs_dev() {
    local ip="$1"
    $SSH_CMD "ec2-user@${ip}" "
VOL_SERIAL=${VOL_ID//-/}
EBS_DEV=\$(lsblk -J -o NAME,SERIAL 2>/dev/null | python3 -c \"
import sys, json
data = json.load(sys.stdin)
for dev in data.get('blockdevices', []):
    if dev.get('serial','') == '\$VOL_SERIAL':
        print('/dev/' + dev['name'])
        break
\" 2>/dev/null || true)
if [[ -z \"\$EBS_DEV\" ]]; then
    for dev in /dev/nvme1n1 /dev/sdf /dev/xvdf; do
        [[ -b \$dev ]] && EBS_DEV=\$dev && break
    done
fi
echo \"\$EBS_DEV\"
"
}

# ---- Helper: check if GFS2 is mounted ----

is_gfs2_mounted() {
    local ip="$1"
    $SSH_CMD "ec2-user@${ip}" "mountpoint -q /mnt/shared 2>/dev/null" 2>/dev/null
}

# ---- Helper: check if etcd is installed ----

is_etcd_installed() {
    local ip="$1"
    $SSH_CMD "ec2-user@${ip}" "test -f /usr/local/bin/etcd" 2>/dev/null
}

# ---- Helper: check if agent is installed ----

is_agent_installed() {
    local ip="$1"
    $SSH_CMD "ec2-user@${ip}" "test -f /usr/local/bin/cluster-agent" 2>/dev/null
}

# ---- Generate TLS certs ----

# Check if existing certs contain the current IPs
CERTS_VALID=false
if [[ -f "$CERT_DIR/ca.crt" ]]; then
    CERTS_VALID=true
    for ip in "${COMPUTE_PRIV_IPS[@]}"; do
        if ! openssl x509 -in "$CERT_DIR/peer-etcd-0.crt" -noout -text 2>/dev/null | grep -q "IP Address: ${ip}"; then
            CERTS_VALID=false
            break
        fi
    done
fi

if [[ "$CERTS_VALID" != "true" ]]; then
    log "Generating TLS certificates..."
    rm -rf "$CERT_DIR" && mkdir -p "$CERT_DIR"

    openssl genrsa -out "$CERT_DIR/ca.key" 2048 2>/dev/null
    openssl req -new -x509 -days 3650 -key "$CERT_DIR/ca.key" \
        -out "$CERT_DIR/ca.crt" -subj "/CN=etcd-ca" 2>/dev/null

    SAN_IPS=""
    for ip in "${COMPUTE_PRIV_IPS[@]}"; do
        [[ -n "$SAN_IPS" ]] && SAN_IPS+=","
        SAN_IPS+="IP:${ip}"
    done
    SAN_IPS+=",IP:127.0.0.1"

    for i in "${!COMPUTE_PRIV_IPS[@]}"; do
        name="etcd-${i}"
        ip="${COMPUTE_PRIV_IPS[$i]}"

        cat > "$CERT_DIR/ext-${name}.cnf" <<EOF
subjectAltName=${SAN_IPS},DNS:${name},DNS:localhost
EOF

        openssl genrsa -out "$CERT_DIR/server-${name}.key" 2048 2>/dev/null
        openssl req -new -key "$CERT_DIR/server-${name}.key" \
            -out "$CERT_DIR/server-${name}.csr" -subj "/CN=${name}" 2>/dev/null
        openssl x509 -req -days 3650 -in "$CERT_DIR/server-${name}.csr" \
            -CA "$CERT_DIR/ca.crt" -CAkey "$CERT_DIR/ca.key" -CAcreateserial \
            -out "$CERT_DIR/server-${name}.crt" \
            -extfile "$CERT_DIR/ext-${name}.cnf" 2>/dev/null

        openssl genrsa -out "$CERT_DIR/peer-${name}.key" 2048 2>/dev/null
        openssl req -new -key "$CERT_DIR/peer-${name}.key" \
            -out "$CERT_DIR/peer-${name}.csr" -subj "/CN=${name}-peer" 2>/dev/null
        openssl x509 -req -days 3650 -in "$CERT_DIR/peer-${name}.csr" \
            -CA "$CERT_DIR/ca.crt" -CAkey "$CERT_DIR/ca.key" -CAcreateserial \
            -out "$CERT_DIR/peer-${name}.crt" \
            -extfile "$CERT_DIR/ext-${name}.cnf" 2>/dev/null
    done

    openssl genrsa -out "$CERT_DIR/client.key" 2048 2>/dev/null
    openssl req -new -key "$CERT_DIR/client.key" \
        -out "$CERT_DIR/client.csr" -subj "/CN=cluster-agent" 2>/dev/null
    openssl x509 -req -days 3650 -in "$CERT_DIR/client.csr" \
        -CA "$CERT_DIR/ca.crt" -CAkey "$CERT_DIR/ca.key" -CAcreateserial \
        -out "$CERT_DIR/client.crt" 2>/dev/null

    chmod 600 "$CERT_DIR"/*.key
    log "TLS certs generated"
else
    log "TLS certs already exist, skipping generation"
fi

# ---- Build initial-cluster string ----

INITIAL_CLUSTER=""
for i in "${!COMPUTE_PRIV_IPS[@]}"; do
    name="etcd-${i}"
    [[ -n "$INITIAL_CLUSTER" ]] && INITIAL_CLUSTER+=","
    INITIAL_CLUSTER+="${name}=https://${COMPUTE_PRIV_IPS[$i]}:2380"
done
log "Initial cluster: $INITIAL_CLUSTER"

# ---- Build cluster-agent locally ----

log "Building cluster-agent locally..."
cd "$PROJECT_ROOT"
go build -o bin/cluster-agent ./cmd/cluster-agent/
log "  binary: $(ls -lh bin/cluster-agent)"

# ---- Setup each node ----

FIRST_NODE=true

for i in "${!COMPUTE_IPS[@]}"; do
    ip="${COMPUTE_IPS[$i]}"
    priv_ip="${COMPUTE_PRIV_IPS[$i]}"
    etcd_name="etcd-${i}"
    node_name="${CLUSTER}-node-$((i+1))"

    log ""
    log "========================================="
    log "Setting up $node_name ($ip, etcd=$etcd_name)"
    log "========================================="

    # --- Install packages (idempotent) ---
    if ! $SSH_CMD "ec2-user@$ip" "rpm -q gcc make flex bison openssl-devel elfutils-libelf-devel git &>/dev/null"; then
        log "Installing packages..."
        $SSH_CMD "ec2-user@$ip" <<'PACKAGES'
set -e
sudo dnf install -y \
    gcc make flex bison openssl-devel elfutils-libelf-devel \
    git rsync 2>&1 | tail -5
sudo dnf install -y kernel-headers 2>&1 | tail -3 || true
PACKAGES
    else
        log "Packages already installed"
    fi

    # --- Install etcd binary (idempotent) ---
    if ! is_etcd_installed "$ip"; then
        log "Installing etcd $ETCD_VER..."
        $SSH_CMD "ec2-user@$ip" <<ETCDINST
set -e
sudo mkdir -p /etc/etcd/tls /var/lib/etcd
sudo chown ec2-user:ec2-user /var/lib/etcd
curl -sLo /tmp/etcd.tar.gz '${ETCD_URL}'
tar xzf /tmp/etcd.tar.gz -C /tmp
sudo mv /tmp/etcd-${ETCD_VER}-linux-amd64/etcd /tmp/etcd-${ETCD_VER}-linux-amd64/etcdctl /usr/local/bin/
sudo chmod 755 /usr/local/bin/etcd /usr/local/bin/etcdctl
rm -rf /tmp/etcd*
ETCDINST
    else
        log "etcd already installed"
    fi

    # --- Push etcd certs ---
    log "Pushing etcd TLS certs..."
    scp $SSH_OPTS \
        "$CERT_DIR/ca.crt" \
        "$CERT_DIR/server-${etcd_name}.crt" "$CERT_DIR/server-${etcd_name}.key" \
        "$CERT_DIR/peer-${etcd_name}.crt" "$CERT_DIR/peer-${etcd_name}.key" \
        "ec2-user@$ip:/tmp/"

    $SSH_CMD "ec2-user@$ip" <<ETCDCERTS
sudo mkdir -p /etc/etcd/tls
sudo mv /tmp/ca.crt /tmp/server-${etcd_name}.crt /tmp/server-${etcd_name}.key \
    /tmp/peer-${etcd_name}.crt /tmp/peer-${etcd_name}.key /etc/etcd/tls/
sudo chown -R root:root /etc/etcd/tls
sudo chmod 600 /etc/etcd/tls/*.key
ETCDCERTS

    # --- etcd systemd unit ---
    log "Creating etcd systemd unit..."
    $SSH_CMD "ec2-user@$ip" "sudo tee /etc/systemd/system/etcd.service" <<'ETCDUNIT'
[Unit]
Description=etcd (colocated)
After=network-online.target
Wants=network-online.target
Documentation=https://etcd.io

[Service]
Type=notify
ExecStart=/bin/true
Restart=always
RestartSec=5
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
ETCDUNIT
    $SSH_CMD "ec2-user@$ip" "sudo mkdir -p /etc/systemd/system/etcd.service.d"

    # --- Push agent certs ---
    log "Pushing agent TLS certs..."
    scp $SSH_OPTS "$CERT_DIR/ca.crt" "ec2-user@$ip:/tmp/"
    scp $SSH_OPTS "$CERT_DIR/client.crt" "ec2-user@$ip:/tmp/"
    scp $SSH_OPTS "$CERT_DIR/client.key" "ec2-user@$ip:/tmp/"
    $SSH_CMD "ec2-user@$ip" <<AGENTCERTS
sudo mkdir -p /etc/cluster-agent
sudo mv /tmp/ca.crt /tmp/client.crt /tmp/client.key /etc/cluster-agent/
sudo chown -R root:root /etc/cluster-agent
sudo chmod 600 /etc/cluster-agent/*.key
AGENTCERTS

    # --- Clean stale etcd data from a previous failed run ---
    # Only clean if etcd is NOT currently running (avoid nuking a live cluster).
    $SSH_CMD "ec2-user@$ip" <<'CLEAN_STALE'
if [ -d /var/lib/etcd/member ] && ! sudo systemctl is-active etcd.service &>/dev/null; then
    echo "Stale etcd data with no running etcd — cleaning"
    sudo rm -rf /var/lib/etcd/member /etc/etcd/etcd.args
fi
CLEAN_STALE

    # --- Push and start cluster-agent ---
    log "Installing cluster-agent..."
    gzip -c "$PROJECT_ROOT/bin/cluster-agent" > /tmp/cluster-agent.gz
    scp $SSH_OPTS /tmp/cluster-agent.gz "ec2-user@$ip:/tmp/"
    rm -f /tmp/cluster-agent.gz

    PEER_URL="https://${priv_ip}:2380"

    $SSH_CMD "ec2-user@$ip" <<AGENT
set -e
gzip -d -f /tmp/cluster-agent.gz; sudo mv /tmp/cluster-agent /usr/local/bin/
sudo chmod 755 /usr/local/bin/cluster-agent

sudo tee /etc/systemd/system/cluster-agent.service > /dev/null <<'EOF'
[Unit]
Description=GFS2 Cluster Agent (etcd-backed, colocated)
After=network-online.target
Wants=network-online.target

[Service]
ExecStartPre=/sbin/modprobe gfs2
ExecStart=/usr/local/bin/cluster-agent \\
  --node-id=NODE_ID_PLACEHOLDER \\
  --etcd-endpoints=ETCD_ENDPOINTS_PLACEHOLDER \\
  --etcd-cert=/etc/cluster-agent/client.crt \\
  --etcd-key=/etc/cluster-agent/client.key \\
  --etcd-ca=/etc/cluster-agent/ca.crt \\
  --etcd-name=ETCD_NAME_PLACEHOLDER \\
  --peer-url=PEER_URL_PLACEHOLDER \\
  --initial-cluster=INITIAL_CLUSTER_PLACEHOLDER \\
  --volume-id=VOL_ID_PLACEHOLDER \\
  --cluster-name=CLUSTER_PLACEHOLDER \\
  --az=AZ_PLACEHOLDER
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

sudo sed -i "s/NODE_ID_PLACEHOLDER/\$(hostname)/" /etc/systemd/system/cluster-agent.service
sudo sed -i "s|ETCD_ENDPOINTS_PLACEHOLDER|${ETCD_ENDPOINTS}|" /etc/systemd/system/cluster-agent.service
sudo sed -i "s/ETCD_NAME_PLACEHOLDER/${etcd_name}/" /etc/systemd/system/cluster-agent.service
sudo sed -i "s|PEER_URL_PLACEHOLDER|${PEER_URL}|" /etc/systemd/system/cluster-agent.service
sudo sed -i "s|INITIAL_CLUSTER_PLACEHOLDER|${INITIAL_CLUSTER}|" /etc/systemd/system/cluster-agent.service
sudo sed -i "s/VOL_ID_PLACEHOLDER/${VOL_ID}/" /etc/systemd/system/cluster-agent.service
sudo sed -i "s/CLUSTER_PLACEHOLDER/${CLUSTER}/" /etc/systemd/system/cluster-agent.service
sudo sed -i "s/AZ_PLACEHOLDER/${AZ}/" /etc/systemd/system/cluster-agent.service

sudo systemctl daemon-reload
sudo systemctl enable etcd
sudo systemctl enable cluster-agent
AGENT

    # --- Format GFS2 (first node only) ---
    if $FIRST_NODE; then
        log "=== First node: starting cluster-agent ==="

        # Start agent and wait for full readiness (bootstrap etcd + register netlink).
        $SSH_CMD "ec2-user@$ip" "sudo systemctl restart cluster-agent"
        log "Waiting for agent to be fully ready (active + etcd healthy + netlink registered)..."
        if ! wait_for_agent_ready "$ip" 90 2; then
            log "ERROR: cluster-agent did not become ready on first node within 3 min"
            exit 1
        fi
        log "Agent ready on $node_name"

        log "=== First node: checking GFS2 ==="

        EBS_DEV=$(detect_ebs_dev "$ip")
        log "EBS device: $EBS_DEV"

        # Check if already formatted
        ALREADY_FORMATTED=$($SSH_CMD "ec2-user@$ip" "
if sudo blkid -s TYPE -o value '$EBS_DEV' 2>/dev/null | grep -q gfs2; then
    echo 'yes'
else
    echo 'no'
fi
" 2>/dev/null || echo "no")

        if [[ "$ALREADY_FORMATTED" == "yes" ]]; then
            log "GFS2 already formatted on $EBS_DEV"
        else
            log "Formatting GFS2..."
            $SSH_CMD "ec2-user@$ip" <<FORMAT
set -e
EBS_DEV="${EBS_DEV}"
echo "Formatting GFS2 on \$EBS_DEV..."
yes | sudo mkfs.gfs2 -p lock_dlm -t ${CLUSTER}:sharedfs -j ${COMPUTE_COUNT} "\$EBS_DEV"
echo "GFS2 formatted"
FORMAT
        fi

        # --- Mount GFS2 ---
        if ! is_gfs2_mounted "$ip"; then
            log "Mounting GFS2..."
            $SSH_CMD "ec2-user@$ip" "
set -e
EBS_DEV=\"${EBS_DEV}\"
sudo mkdir -p /mnt/shared
sudo mount -t gfs2 -o lockproto=lock_etcd,locktable=${CLUSTER}:sharedfs,noatime \\
    \"\$EBS_DEV\" /mnt/shared
echo 'GFS2 mounted'
df -h /mnt/shared
"
        else
            log "GFS2 already mounted"
        fi

        FIRST_NODE=false
    else
        # --- Mount GFS2 (other nodes) ---
        log "=== $node_name: starting cluster-agent ==="

        # Start agent and wait for full readiness (join etcd cluster + register netlink).
        $SSH_CMD "ec2-user@$ip" "sudo systemctl restart cluster-agent"
        log "Waiting for agent to be fully ready (active + etcd healthy + netlink registered)..."
        if ! wait_for_agent_ready "$ip" 90 2; then
            log "ERROR: cluster-agent did not become ready on $node_name within 3 min"
            exit 1
        fi
        log "Agent ready on $node_name"

        # Give the agent a moment to stabilize after netlink registration.
        sleep 3

        log "=== Mounting GFS2 ==="

        EBS_DEV=$(detect_ebs_dev "$ip")
        log "EBS device: $EBS_DEV"

        # Mount
        if ! is_gfs2_mounted "$ip"; then
            log "Mounting GFS2..."
            $SSH_CMD "ec2-user@$ip" "
set -e
EBS_DEV=\"${EBS_DEV}\"
sudo mkdir -p /mnt/shared
sudo mount -t gfs2 -o lockproto=lock_etcd,locktable=${CLUSTER}:sharedfs,noatime \\
    \"\$EBS_DEV\" /mnt/shared
echo 'GFS2 mounted'
df -h /mnt/shared
"
        else
            log "GFS2 already mounted"
        fi
    fi

    log "$node_name setup complete."
done

log ""
log "=== All compute nodes ready (etcd colocated) ==="
log "etcd endpoints: $ETCD_ENDPOINTS"
log "Run: ./scripts/infra/run-full-test.sh"
