#!/bin/bash
# setup-compute.sh — install etcd + cluster-agent + lock_etcd + GFS2 on compute nodes.
#
# Etcd is colocated on each compute node (no dedicated etcd instances).
# For each compute node:
#   1. Install etcd binary + etcd systemd unit
#   2. Generate mTLS certs (compute IPs as SANs)
#   3. Install kernel headers + build tools + gfs2-utils
#   4. Build and load lock_etcd kernel module
#   5. Build and start cluster-agent (Go daemon) with colocation flags
#   6. Format GFS2 (first node only)
#   7. Mount GFS2 (all nodes)
#
# Prerequisites: create-infra.sh must have run.
#
# The cluster-agent handles etcd bootstrap (new cluster or join existing)
# via its --etcd-name, --peer-url, and --initial-cluster flags.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$SCRIPT_DIR/state.sh"

PEM="${PEM_PATH/#\~/$HOME}"
SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=10 -i $PEM"

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

# ---- Generate TLS certs (with compute IPs as SANs) ----

log "Generating TLS certificates for all nodes..."

rm -rf "$CERT_DIR" && mkdir -p "$CERT_DIR"

openssl genrsa -out "$CERT_DIR/ca.key" 2048 2>/dev/null
openssl req -new -x509 -days 3650 -key "$CERT_DIR/ca.key" \
    -out "$CERT_DIR/ca.crt" -subj "/CN=etcd-ca" 2>/dev/null

# Build SAN string with all compute IPs + localhost.
SAN_IPS=""
for ip in "${COMPUTE_PRIV_IPS[@]}"; do
    [[ -n "$SAN_IPS" ]] && SAN_IPS+=","
    SAN_IPS+="IP:${ip}"
done
# Add localhost for bootstrap when etcd checks its own endpoint.
SAN_IPS+=",IP:127.0.0.1"

for i in "${!COMPUTE_PRIV_IPS[@]}"; do
    name="etcd-${i}"
    ip="${COMPUTE_PRIV_IPS[$i]}"

    cat > "$CERT_DIR/ext-${name}.cnf" <<EOF
subjectAltName=${SAN_IPS},DNS:${name},DNS:localhost
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

# Client cert (for cluster-agent → etcd connection)
openssl genrsa -out "$CERT_DIR/client.key" 2048 2>/dev/null
openssl req -new -key "$CERT_DIR/client.key" \
    -out "$CERT_DIR/client.csr" -subj "/CN=cluster-agent" 2>/dev/null
openssl x509 -req -days 3650 -in "$CERT_DIR/client.csr" \
    -CA "$CERT_DIR/ca.crt" -CAkey "$CERT_DIR/ca.key" -CAcreateserial \
    -out "$CERT_DIR/client.crt" 2>/dev/null

chmod 600 "$CERT_DIR"/*.key

# ---- Build initial-cluster string ----

INITIAL_CLUSTER=""
for i in "${!COMPUTE_PRIV_IPS[@]}"; do
    name="etcd-${i}"
    [[ -n "$INITIAL_CLUSTER" ]] && INITIAL_CLUSTER+=","
    INITIAL_CLUSTER+="${name}=https://${COMPUTE_PRIV_IPS[$i]}:2380"
done
log "Initial cluster: $INITIAL_CLUSTER"

# ---- Build cluster-agent locally, then push ----

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

    # --- Install packages ---
    log "Installing packages..."
    ssh $SSH_OPTS "ec2-user@$ip" <<PACKAGES
set -e
sudo dnf install -y \
    kernel-devel-\$(uname -r) \
    kernel-headers \
    gcc make flex bison openssl-devel elfutils-libelf-devel \
    git rsync 2>&1 | tail -5

# gfs2-utils is not in AL2023 repos — install from AlmaLinux 9 RPM.
if [[ ! -f /usr/sbin/mkfs.gfs2 ]]; then
    GFS2_RPM="gfs2-utils-3.5.1-3.el9.x86_64.rpm"
    GFS2_URL="https://repo.almalinux.org/almalinux/9/ResilientStorage/x86_64/os/Packages/\${GFS2_RPM}"
    curl -sLO "\$GFS2_URL"
    sudo dnf --nogpgcheck install -y "./\${GFS2_RPM}" 2>&1 | tail -5
    rm -f "\${GFS2_RPM}"
    echo "gfs2-utils installed: \$(which mkfs.gfs2)"
fi
PACKAGES

    # --- Install etcd binary ---
    log "Installing etcd $ETCD_VER..."
    ssh $SSH_OPTS "ec2-user@$ip" <<ETCDINST
set -e
sudo mkdir -p /etc/etcd/tls /var/lib/etcd
sudo chown ec2-user:ec2-user /var/lib/etcd
if [[ ! -f /usr/local/bin/etcd ]]; then
    curl -sLo /tmp/etcd.tar.gz '$ETCD_URL'
    tar xzf /tmp/etcd.tar.gz -C /tmp
    sudo mv /tmp/etcd-${ETCD_VER}-linux-amd64/etcd /tmp/etcd-${ETCD_VER}-linux-amd64/etcdctl /usr/local/bin/
    sudo chmod 755 /usr/local/bin/etcd /usr/local/bin/etcdctl
    rm -rf /tmp/etcd*
fi
ETCDINST

    # --- Push etcd certs ---
    log "Pushing etcd TLS certs..."
    scp $SSH_OPTS \
        "$CERT_DIR/ca.crt" \
        "$CERT_DIR/server-${etcd_name}.crt" "$CERT_DIR/server-${etcd_name}.key" \
        "$CERT_DIR/peer-${etcd_name}.crt" "$CERT_DIR/peer-${etcd_name}.key" \
        "ec2-user@$ip:/tmp/"

    ssh $SSH_OPTS "ec2-user@$ip" <<ETCDCERTS
sudo mkdir -p /etc/etcd/tls
sudo mv /tmp/ca.crt /tmp/server-${etcd_name}.crt /tmp/server-${etcd_name}.key \
    /tmp/peer-${etcd_name}.crt /tmp/peer-${etcd_name}.key /etc/etcd/tls/
sudo chown -R root:root /etc/etcd/tls
sudo chmod 600 /etc/etcd/tls/*.key
ETCDCERTS

    # --- etcd systemd unit (drop-in written by agent during bootstrap) ---
    log "Creating etcd systemd unit..."
    ssh $SSH_OPTS "ec2-user@$ip" "sudo tee /etc/systemd/system/etcd.service" <<'ETCDUNIT'
[Unit]
Description=etcd (colocated)
After=network-online.target
Wants=network-online.target
Documentation=https://etcd.io

[Service]
Type=notify
# ExecStart is overridden by a drop-in written by cluster-agent during bootstrap.
ExecStart=/bin/true
Restart=always
RestartSec=5
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
ETCDUNIT
    ssh $SSH_OPTS "ec2-user@$ip" "sudo mkdir -p /etc/systemd/system/etcd.service.d"

    # --- Push client certs for agent ---
    log "Pushing agent TLS certs..."
    scp $SSH_OPTS "$CERT_DIR/ca.crt" "ec2-user@$ip:/tmp/"
    scp $SSH_OPTS "$CERT_DIR/client.crt" "ec2-user@$ip:/tmp/"
    scp $SSH_OPTS "$CERT_DIR/client.key" "ec2-user@$ip:/tmp/"
    ssh $SSH_OPTS "ec2-user@$ip" <<AGENTCERTS
sudo mkdir -p /etc/cluster-agent
sudo mv /tmp/ca.crt /tmp/client.crt /tmp/client.key /etc/cluster-agent/
sudo chown -R root:root /etc/cluster-agent
sudo chmod 600 /etc/cluster-agent/*.key
AGENTCERTS

    # --- Build and load kernel module ---
    log "Building lock_etcd kernel module..."
    ssh $SSH_OPTS "ec2-user@$ip" <<KMOD
set -e
echo "Kernel: \$(uname -r)"
echo "Headers: \$(ls /lib/modules/\$(uname -r)/build/include/linux/version.h 2>/dev/null && echo OK || echo MISSING)"
KMOD

    log "Syncing kernel source..."
    # Copy the shared header into kernel dir for the build.
    cp "$PROJECT_ROOT/pkg/protocol/letcd_netlink.h" "$PROJECT_ROOT/kernel/letcd_netlink.h"
    rsync -avz -e "ssh $SSH_OPTS" \
        --exclude='*.o' --exclude='*.ko' --exclude='*.mod*' \
        --exclude='.git' \
        "$PROJECT_ROOT/kernel/" "ec2-user@$ip:/tmp/lock_etcd_kernel/"

    ssh $SSH_OPTS "ec2-user@$ip" <<'BUILD_MOD'
set -e
cd /tmp/lock_etcd_kernel

# Extract GFS2 internal headers from kernel source RPM.
if [[ ! -f glock.h ]] || [[ ! -f incore.h ]]; then
    KVER=$(uname -r)
    if [[ ! -f "/tmp/kernel-${KVER}.src.rpm" ]]; then
        sudo dnf download --source kernel --downloaddir /tmp/ 2>&1 | tail -2
    fi
    cd /tmp
    rpm2cpio "kernel-${KVER}.src.rpm" | cpio -idmv "linux-6.1.175.tar.xz" 2>&1 | tail -1
    tar xf linux-6.1.175.tar.xz --wildcards "linux-6.1.175/fs/gfs2/*.h" 2>&1 | tail -3
    cp linux-6.1.175/fs/gfs2/*.h /tmp/lock_etcd_kernel/
    echo "GFS2 headers ready"
    cd /tmp/lock_etcd_kernel
fi

make -C /lib/modules/$(uname -r)/build M=$(pwd) modules 2>&1 | tail -5
if [[ -f lock_etcd.ko ]]; then
    echo "Module built: $(ls -lh lock_etcd.ko)"
else
    echo "ERROR: module build failed"
    exit 1
fi
sudo insmod lock_etcd.ko
lsmod | grep lock_etcd || echo "WARNING: module not in lsmod"
cat /proc/net/netlink | grep -P '^31\b' && echo "Netlink family 31 registered" || true
BUILD_MOD

    # --- Push and start cluster-agent ---
    log "Installing cluster-agent..."
    scp $SSH_OPTS "$PROJECT_ROOT/bin/cluster-agent" "ec2-user@$ip:/tmp/"

    PEER_URL="https://${priv_ip}:2380"

    ssh $SSH_OPTS "ec2-user@$ip" <<AGENT
set -e
sudo mv /tmp/cluster-agent /usr/local/bin/
sudo chmod 755 /usr/local/bin/cluster-agent

# Create systemd unit for cluster-agent (etcd colocated).
# Agent boots first: on startup it bootstraps/joins etcd, then listens for kernel.
# etcd.service starts as a dependency so systemd knows the relationship.
sudo tee /etc/systemd/system/cluster-agent.service > /dev/null <<'EOF'
[Unit]
Description=GFS2 Cluster Agent (etcd-backed, colocated)
After=network-online.target
Wants=network-online.target

[Service]
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
sudo systemctl restart cluster-agent
sleep 5
echo "--- cluster-agent status ---"
sudo systemctl status cluster-agent --no-pager | head -15
AGENT

    # --- Format GFS2 (first node only) ---
    if $FIRST_NODE; then
        log "=== First node: formatting GFS2 ==="

        # Wait for agent to bootstrap etcd and register in cluster
        sleep 15

        ssh $SSH_OPTS "ec2-user@$ip" <<FORMAT
set -e

# Find the EBS device (usually /dev/nvme1n1 or /dev/sdf)
EBS_DEV=\$(lsblk -o NAME,SERIAL | grep vol${VOL_ID#vol-} | awk '{print "/dev/"\$1}' | head -1)
if [[ -z "\$EBS_DEV" ]]; then
    for dev in /dev/nvme1n1 /dev/sdf /dev/xvdf; do
        [[ -b \$dev ]] && EBS_DEV=\$dev && break
    done
fi

echo "EBS device: \$EBS_DEV"

# Format with lock_etcd protocol
sudo mkfs.gfs2 -p lock_etcd -t ${CLUSTER}:sharedfs -j ${COMPUTE_COUNT} "\$EBS_DEV"
echo "GFS2 formatted on \$EBS_DEV"

# Mount
sudo mkdir -p /mnt/shared
sudo mount -t gfs2 -o lockproto=lock_etcd,locktable=${CLUSTER}:sharedfs,noatime \
    "\$EBS_DEV" /mnt/shared
echo "GFS2 mounted at /mnt/shared"
df -h /mnt/shared
FORMAT
        FIRST_NODE=false
    else
        # --- Mount GFS2 (other nodes) ---
        log "=== Mounting GFS2 ==="

        # Wait for first node to finish formatting + etcd join to complete
        sleep 20

        ssh $SSH_OPTS "ec2-user@$ip" <<MOUNT
set -e
EBS_DEV=\$(lsblk -o NAME,SERIAL | grep vol${VOL_ID#vol-} | awk '{print "/dev/"\$1}' | head -1)
[[ -z "\$EBS_DEV" ]] && { for dev in /dev/nvme1n1 /dev/sdf /dev/xvdf; do [[ -b \$dev ]] && EBS_DEV=\$dev && break; done; }

sudo mkdir -p /mnt/shared
sudo mount -t gfs2 -o lockproto=lock_etcd,locktable=${CLUSTER}:sharedfs,noatime \
    "\$EBS_DEV" /mnt/shared
echo "GFS2 mounted at /mnt/shared"
df -h /mnt/shared
MOUNT
    fi

    log "$node_name setup complete."
done

log ""
log "=== All compute nodes ready (etcd colocated) ==="
log "etcd endpoints: $ETCD_ENDPOINTS"
log "Run: ./scripts/infra/run-full-test.sh"
