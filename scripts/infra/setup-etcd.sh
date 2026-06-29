#!/bin/bash
# setup-etcd.sh — install etcd cluster with mTLS on etcd nodes.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$SCRIPT_DIR/state.sh"

PEM="${PEM_PATH/#\~/$HOME}"
SSH="ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 -i $PEM"

mapfile -t IPS < <(state_get etcd_ips | jq -r '.[]')
mapfile -t PUB_IPS < <(state_get etcd_public_ips | jq -r '.[]')
COUNT=${#IPS[@]}
[[ "$COUNT" -gt 0 ]] || die "No etcd IPs in state file"

log "=== etcd cluster setup ($COUNT nodes) ==="

# ---- Build peer list ----
INITIAL_CLUSTER=""
for i in "${!IPS[@]}"; do
    name="etcd-$((i+1))"
    [[ -n "$INITIAL_CLUSTER" ]] && INITIAL_CLUSTER+=","
    INITIAL_CLUSTER+="${name}=https://${IPS[$i]}:2380"
done

# ---- Generate TLS certs ----
CERT_DIR="$PROJECT_ROOT/certs"
rm -rf "$CERT_DIR" && mkdir -p "$CERT_DIR"

log "Generating certificates..."
openssl genrsa -out "$CERT_DIR/ca.key" 2048 2>/dev/null
openssl req -new -x509 -days 3650 -key "$CERT_DIR/ca.key" \
    -out "$CERT_DIR/ca.crt" -subj "/CN=etcd-ca" 2>/dev/null

for i in "${!IPS[@]}"; do
    name="etcd-$((i+1))"
    ip="${IPS[$i]}"
    cat > "$CERT_DIR/ext-${name}.cnf" <<EOF
subjectAltName=IP:${ip},DNS:${name},DNS:localhost
EOF
    # Server cert
    openssl genrsa -out "$CERT_DIR/server-${name}.key" 2048 2>/dev/null
    openssl req -new -key "$CERT_DIR/server-${name}.key" \
        -out "$CERT_DIR/server-${name}.csr" -subj "/CN=${name}" 2>/dev/null
    openssl x509 -req -days 3650 -in "$CERT_DIR/server-${name}.csr" \
        -CA "$CERT_DIR/ca.crt" -CAkey "$CERT_DIR/ca.key" -CAcreateserial \
        -out "$CERT_DIR/server-${name}.crt" \
        -extfile "$CERT_DIR/ext-${name}.cnf" 2>/dev/null
    # Peer cert
    openssl genrsa -out "$CERT_DIR/peer-${name}.key" 2048 2>/dev/null
    openssl req -new -key "$CERT_DIR/peer-${name}.key" \
        -out "$CERT_DIR/peer-${name}.csr" -subj "/CN=${name}-peer" 2>/dev/null
    openssl x509 -req -days 3650 -in "$CERT_DIR/peer-${name}.csr" \
        -CA "$CERT_DIR/ca.crt" -CAkey "$CERT_DIR/ca.key" -CAcreateserial \
        -out "$CERT_DIR/peer-${name}.crt" \
        -extfile "$CERT_DIR/ext-${name}.cnf" 2>/dev/null
done

# Client cert
openssl genrsa -out "$CERT_DIR/client.key" 2048 2>/dev/null
openssl req -new -key "$CERT_DIR/client.key" \
    -out "$CERT_DIR/client.csr" -subj "/CN=cluster-agent" 2>/dev/null
openssl x509 -req -days 3650 -in "$CERT_DIR/client.csr" \
    -CA "$CERT_DIR/ca.crt" -CAkey "$CERT_DIR/ca.key" -CAcreateserial \
    -out "$CERT_DIR/client.crt" 2>/dev/null

chmod 600 "$CERT_DIR"/*.key

# ---- Install etcd on each node ----
ETCD_VER="v3.5.18"
ETCD_URL="https://github.com/etcd-io/etcd/releases/download/${ETCD_VER}/etcd-${ETCD_VER}-linux-amd64.tar.gz"

for i in "${!IPS[@]}"; do
    ip="${IPS[$i]}"
    pub="${PUB_IPS[$i]}"
    name="etcd-$((i+1))"
    log "--- Setting up $name ($pub / $ip) ---"

    # Install etcd binary
    $SSH "ec2-user@$pub" "sudo mkdir -p /etc/etcd/tls /var/lib/etcd && sudo chown ec2-user:ec2-user /var/lib/etcd"
    $SSH "ec2-user@$pub" "curl -sLo /tmp/etcd.tar.gz '$ETCD_URL' && tar xzf /tmp/etcd.tar.gz -C /tmp && sudo mv /tmp/etcd-${ETCD_VER}-linux-amd64/etcd /tmp/etcd-${ETCD_VER}-linux-amd64/etcdctl /usr/local/bin/ && rm -rf /tmp/etcd*"
    $SSH "ec2-user@$pub" "sudo chmod 755 /usr/local/bin/etcd /usr/local/bin/etcdctl"

    # Push certs
    scp -o StrictHostKeyChecking=no -i "$PEM" \
        "$CERT_DIR/ca.crt" "$CERT_DIR/server-${name}.crt" "$CERT_DIR/server-${name}.key" \
        "$CERT_DIR/peer-${name}.crt" "$CERT_DIR/peer-${name}.key" \
        "ec2-user@$pub:/tmp/"
    $SSH "ec2-user@$pub" "sudo mv /tmp/ca.crt /tmp/server-${name}.crt /tmp/server-${name}.key /tmp/peer-${name}.crt /tmp/peer-${name}.key /etc/etcd/tls/ && sudo chown -R root:root /etc/etcd/tls && sudo chmod 600 /etc/etcd/tls/*.key"

    # Create systemd unit
    $SSH "ec2-user@$pub" "sudo tee /etc/systemd/system/etcd.service" <<UNIT
[Unit]
Description=etcd
After=network-online.target

[Service]
ExecStart=/usr/local/bin/etcd \\
  --name ${name} \\
  --data-dir /var/lib/etcd \\
  --listen-client-urls https://0.0.0.0:2379 \\
  --advertise-client-urls https://${ip}:2379 \\
  --listen-peer-urls https://0.0.0.0:2380 \\
  --initial-advertise-peer-urls https://${ip}:2380 \\
  --initial-cluster ${INITIAL_CLUSTER} \\
  --initial-cluster-state new \\
  --client-cert-auth \\
  --trusted-ca-file /etc/etcd/tls/ca.crt \\
  --cert-file /etc/etcd/tls/server-${name}.crt \\
  --key-file /etc/etcd/tls/server-${name}.key \\
  --peer-client-cert-auth \\
  --peer-trusted-ca-file /etc/etcd/tls/ca.crt \\
  --peer-cert-file /etc/etcd/tls/peer-${name}.crt \\
  --peer-key-file /etc/etcd/tls/peer-${name}.key
Restart=always
RestartSec=5
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
UNIT

    $SSH "ec2-user@$pub" "sudo systemctl daemon-reload && sudo systemctl enable etcd && sudo systemctl restart etcd"
    log "  $name started"
done

# ---- Verify ----
sleep 10
PUB0="${PUB_IPS[0]}"
IP0="${IPS[0]}"
log "Verifying etcd health via $PUB0..."
$SSH "ec2-user@$PUB0" "sudo ETCDCTL_API=3 etcdctl --endpoints=https://localhost:2379 --cacert=/etc/etcd/tls/ca.crt --cert=/etc/etcd/tls/server-etcd-1.crt --key=/etc/etcd/tls/server-etcd-1.key endpoint health --cluster"

# ---- Save endpoints ----
ENDPOINTS=""
for ip in "${IPS[@]}"; do
    [[ -n "$ENDPOINTS" ]] && ENDPOINTS+=","
    ENDPOINTS+="https://${ip}:2379"
done
state_put etcd_nlb_dns "\"$ENDPOINTS\""

log ""
log "=== etcd cluster ready ==="
log "Endpoints: $ENDPOINTS"
log "Client certs: ca=$CERT_DIR/ca.crt cert=$CERT_DIR/client.crt key=$CERT_DIR/client.key"
