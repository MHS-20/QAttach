#!/bin/bash
# setup-etcd.sh — install and configure etcd cluster on etcd nodes.
#
# Reads etcd IPs from infra state. For each node:
#   1. Installs etcd via SSH
#   2. Generates mTLS certs (one CA, per-node server cert, one client cert)
#   3. Starts etcd with systemd
#
# Prerequisites: create-infra.sh must have run successfully.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$SCRIPT_DIR/state.sh"

PEM="${PEM_PATH/#\~/$HOME}"
SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=10 -i $PEM"

mapfile -t ETCD_IP_ARRAY < <(state_get etcd_ips | jq -r '.[]')
ETCD_COUNT=${#ETCD_IP_ARRAY[@]}

if [[ "$ETCD_COUNT" -eq 0 ]]; then
    die "No etcd IPs in state file. Run create-infra.sh first."
fi

log "=== etcd cluster setup ($ETCD_COUNT nodes) ==="
log "IPs: ${ETCD_IP_ARRAY[*]}"
log ""

# ---- Step 1: Build etcd peer list ----

INITIAL_CLUSTER=""
for i in "${!ETCD_IP_ARRAY[@]}"; do
    ip="${ETCD_IP_ARRAY[$i]}"
    name="etcd-$((i+1))"
    [[ -n "$INITIAL_CLUSTER" ]] && INITIAL_CLUSTER+=","
    INITIAL_CLUSTER+="${name}=https://${ip}:2380"
done

# ---- Step 2: Generate TLS certs (locally, then push) ----

CERT_DIR="$PROJECT_ROOT/certs"
rm -rf "$CERT_DIR"
mkdir -p "$CERT_DIR"

log "Generating TLS certificates..."

# CA key + cert
openssl genrsa -out "$CERT_DIR/ca.key" 2048 2>/dev/null
openssl req -new -x509 -days 3650 -key "$CERT_DIR/ca.key" \
    -out "$CERT_DIR/ca.crt" \
    -subj "/CN=etcd-ca" 2>/dev/null

# Server cert for each etcd node
for i in "${!ETCD_IP_ARRAY[@]}"; do
    ip="${ETCD_IP_ARRAY[$i]}"
    name="etcd-$((i+1))"

    openssl genrsa -out "$CERT_DIR/server-${name}.key" 2048 2>/dev/null
    openssl req -new -key "$CERT_DIR/server-${name}.key" \
        -out "$CERT_DIR/server-${name}.csr" \
        -subj "/CN=${name}" \
        -addext "subjectAltName=IP:${ip},DNS:${name}" 2>/dev/null

    # Create extfile for SAN
    cat > "$CERT_DIR/ext-${name}.cnf" <<EOF
subjectAltName=IP:${ip},DNS:${name},DNS:localhost
EOF
    openssl x509 -req -days 3650 \
        -in "$CERT_DIR/server-${name}.csr" \
        -CA "$CERT_DIR/ca.crt" -CAkey "$CERT_DIR/ca.key" -CAcreateserial \
        -out "$CERT_DIR/server-${name}.crt" \
        -extfile "$CERT_DIR/ext-${name}.cnf" 2>/dev/null

    # Peer cert (same CA, different CN avoids issues)
    openssl genrsa -out "$CERT_DIR/peer-${name}.key" 2048 2>/dev/null
    openssl req -new -key "$CERT_DIR/peer-${name}.key" \
        -out "$CERT_DIR/peer-${name}.csr" \
        -subj "/CN=${name}-peer" 2>/dev/null
    openssl x509 -req -days 3650 \
        -in "$CERT_DIR/peer-${name}.csr" \
        -CA "$CERT_DIR/ca.crt" -CAkey "$CERT_DIR/ca.key" -CAcreateserial \
        -out "$CERT_DIR/peer-${name}.crt" \
        -extfile "$CERT_DIR/ext-${name}.cnf" 2>/dev/null
done

# Client cert (one for the cluster-agent)
openssl genrsa -out "$CERT_DIR/client.key" 2048 2>/dev/null
openssl req -new -key "$CERT_DIR/client.key" \
    -out "$CERT_DIR/client.csr" \
    -subj "/CN=cluster-agent" 2>/dev/null
openssl x509 -req -days 3650 \
    -in "$CERT_DIR/client.csr" \
    -CA "$CERT_DIR/ca.crt" -CAkey "$CERT_DIR/ca.key" -CAcreateserial \
    -out "$CERT_DIR/client.crt" 2>/dev/null

chmod 600 "$CERT_DIR"/*.key
log "Certs generated in $CERT_DIR"

# ---- Step 3: Install etcd on each node ----

ETCD_VERSION="v3.5.18"
ETCD_URL="https://github.com/etcd-io/etcd/releases/download/${ETCD_VERSION}/etcd-${ETCD_VERSION}-linux-amd64.tar.gz"

for i in "${!ETCD_IP_ARRAY[@]}"; do
    ip="${ETCD_IP_ARRAY[$i]}"
    name="etcd-$((i+1))"

    log ""
    log "--- Setting up $name ($ip) ---"

    # Install etcd binary
    ssh $SSH_OPTS "ec2-user@$ip" <<'SETUP'
set -e
sudo mkdir -p /etc/etcd /var/lib/etcd
sudo chown ec2-user:ec2-user /var/lib/etcd

# Download etcd
if [[ ! -f /usr/local/bin/etcd ]]; then
    curl -sLO ETCD_URL_PLACEHOLDER
    tar xzf etcd-*.tar.gz
    sudo mv etcd-*/etcd etcd-*/etcdctl etcd-*/etcdutl /usr/local/bin/
    rm -rf etcd-*
fi
echo "etcd binary: $(etcd --version | head -1)"
SETUP
    # Replace placeholder with actual URL
    ssh $SSH_OPTS "ec2-user@$ip" "sudo sed -i 's|ETCD_URL_PLACEHOLDER|$ETCD_URL|g' /tmp/etcd-setup.sh 2>/dev/null; sudo bash -c 'cd /tmp && curl -sLO $ETCD_URL && tar xzf etcd-*.tar.gz && mv etcd-*/etcd etcd-*/etcdctl etcd-*/etcdutl /usr/local/bin/ && rm -rf etcd-*'"

    # Push certs
    scp $SSH_OPTS "$CERT_DIR/ca.crt" "ec2-user@$ip:/tmp/ca.crt"
    scp $SSH_OPTS "$CERT_DIR/server-${name}.crt" "ec2-user@$ip:/tmp/server.crt"
    scp $SSH_OPTS "$CERT_DIR/server-${name}.key" "ec2-user@$ip:/tmp/server.key"
    scp $SSH_OPTS "$CERT_DIR/peer-${name}.crt" "ec2-user@$ip:/tmp/peer.crt"
    scp $SSH_OPTS "$CERT_DIR/peer-${name}.key" "ec2-user@$ip:/tmp/peer.key"

    ssh $SSH_OPTS "ec2-user@$ip" <<CERT
sudo mkdir -p /etc/etcd/tls
sudo mv /tmp/ca.crt /tmp/server.crt /tmp/server.key /tmp/peer.crt /tmp/peer.key /etc/etcd/tls/
sudo chown -R root:root /etc/etcd/tls
sudo chmod 600 /etc/etcd/tls/*.key
CERT

    # Create systemd unit
    ssh $SSH_OPTS "ec2-user@$ip" <<UNIT
sudo tee /etc/systemd/system/etcd.service > /dev/null <<'EOF'
[Unit]
Description=etcd
After=network-online.target
Wants=network-online.target

[Service]
ExecStart=/usr/local/bin/etcd \\
  --name NAME_PLACEHOLDER \\
  --data-dir /var/lib/etcd \\
  --listen-client-urls https://0.0.0.0:2379 \\
  --advertise-client-urls https://IP_PLACEHOLDER:2379 \\
  --listen-peer-urls https://0.0.0.0:2380 \\
  --initial-advertise-peer-urls https://IP_PLACEHOLDER:2380 \\
  --initial-cluster INITIAL_CLUSTER_PLACEHOLDER \\
  --initial-cluster-state new \\
  --client-cert-auth \\
  --trusted-ca-file /etc/etcd/tls/ca.crt \\
  --cert-file /etc/etcd/tls/server.crt \\
  --key-file /etc/etcd/tls/server.key \\
  --peer-client-cert-auth \\
  --peer-trusted-ca-file /etc/etcd/tls/ca.crt \\
  --peer-cert-file /etc/etcd/tls/peer.crt \\
  --peer-key-file /etc/etcd/tls/peer.key
Restart=always
RestartSec=5
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF

sudo sed -i "s/NAME_PLACEHOLDER/${name}/" /etc/systemd/system/etcd.service
sudo sed -i "s/IP_PLACEHOLDER/${ip}/" /etc/systemd/system/etcd.service
sudo sed -i "s|INITIAL_CLUSTER_PLACEHOLDER|${INITIAL_CLUSTER}|" /etc/systemd/system/etcd.service
UNIT

    # Start etcd
    ssh $SSH_OPTS "ec2-user@$ip" <<START
sudo systemctl daemon-reload
sudo systemctl enable etcd
sudo systemctl restart etcd
sleep 3
sudo systemctl status etcd --no-pager | head -10
START

    log "  $name started"
done

# ---- Step 4: Verify cluster health ----

log ""
log "Waiting for etcd cluster to form (10s)..."
sleep 10

IP0="${ETCD_IP_ARRAY[0]}"
ENDPOINT="https://${IP0}:2379"

log "Verifying etcd health..."
ssh $SSH_OPTS "ec2-user@$IP0" <<VERIFY
ETCDCTL_API=3 etcdctl \
  --endpoints=https://localhost:2379 \
  --cacert=/etc/etcd/tls/ca.crt \
  --cert=/etc/etcd/tls/server.crt \
  --key=/etc/etcd/tls/server.key \
  endpoint health --cluster
VERIFY

log ""
log "=== etcd cluster ready ==="
ENDPOINTS=""
for ip in "${ETCD_IP_ARRAY[@]}"; do
    echo "  https://${ip}:2379"
    [[ -n "$ENDPOINTS" ]] && ENDPOINTS+=","
    ENDPOINTS+="https://${ip}:2379"
done
# Update state with comma-separated endpoints
state_put etcd_nlb_dns "\"$ENDPOINTS\""
log ""
log "Client certs for cluster-agent:"
log "  CA:   $CERT_DIR/ca.crt"
log "  Cert: $CERT_DIR/client.crt"
log "  Key:  $CERT_DIR/client.key"
