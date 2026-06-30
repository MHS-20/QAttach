#!/bin/bash
# setup-compute.sh — install cluster-agent + lock_etcd + GFS2 on compute nodes.
#
# For each compute node:
#   1. Install kernel headers + build tools + gfs2-utils
#   2. Build and load lock_etcd kernel module
#   3. Build and start cluster-agent (Go daemon)
#   4. Format GFS2 (first node only)
#   5. Mount GFS2 (all nodes)
#
# Prerequisites: create-infra.sh + setup-etcd.sh must have run.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$SCRIPT_DIR/state.sh"

PEM="${PEM_PATH/#\~/$HOME}"
SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=10 -i $PEM"

mapfile -t COMPUTE_IPS < <(state_get compute_public_ips | jq -r '.[]')
if [[ -z "${COMPUTE_IPS[*]}" || "${COMPUTE_IPS[0]}" == "null" ]]; then
    # fallback: no public IPs in state, use private
    mapfile -t COMPUTE_IPS < <(state_get compute_ips | jq -r '.[]')
fi
COMPUTE_COUNT=${#COMPUTE_IPS[@]}

if [[ "$COMPUTE_COUNT" -eq 0 ]]; then
    die "No compute IPs in state file."
fi

ETCD_ENDPOINTS=$(state_get etcd_nlb_dns)
if [[ -z "$ETCD_ENDPOINTS" || "$ETCD_ENDPOINTS" == "null" ]]; then
    die "etcd endpoints not found. Run setup-etcd.sh first."
fi

VOL_ID=$(state_get volume_id)
CLUSTER=$(state_get cluster_name)
CERT_DIR="$PROJECT_ROOT/certs"

log "=== Compute node setup ($COMPUTE_COUNT nodes) ==="
log "etcd:        $ETCD_ENDPOINTS"
log "Volume:      $VOL_ID"
log "Cluster:     $CLUSTER"
log ""

# ---- Build cluster-agent locally, then push ----

log "Building cluster-agent locally..."
cd "$PROJECT_ROOT"
go build -o bin/cluster-agent ./cmd/cluster-agent/
log "  binary: $(ls -lh bin/cluster-agent)"

# ---- Setup each node ----

FIRST_NODE=true

for i in "${!COMPUTE_IPS[@]}"; do
    ip="${COMPUTE_IPS[$i]}"
    node_name="${CLUSTER}-node-$((i+1))"

    log ""
    log "========================================="
    log "Setting up $node_name ($ip)"
    log "========================================="

    # --- Install packages ---
    log "Installing packages..."
    ssh $SSH_OPTS "ec2-user@$ip" <<PACKAGES
set -e
sudo dnf install -y \
    gfs2-utils \
    kernel-devel-\$(uname -r) \
    kernel-headers \
    gcc make flex bison openssl-devel elfutils-libelf-devel \
    git rsync 2>&1 | tail -3
PACKAGES

    # --- Push TLS certs ---
    log "Pushing TLS certs..."
    scp $SSH_OPTS "$CERT_DIR/ca.crt" "ec2-user@$ip:/tmp/"
    scp $SSH_OPTS "$CERT_DIR/client.crt" "ec2-user@$ip:/tmp/"
    scp $SSH_OPTS "$CERT_DIR/client.key" "ec2-user@$ip:/tmp/"
    ssh $SSH_OPTS "ec2-user@$ip" <<CERTS
sudo mkdir -p /etc/cluster-agent
sudo mv /tmp/ca.crt /tmp/client.crt /tmp/client.key /etc/cluster-agent/
sudo chown -R root:root /etc/cluster-agent
sudo chmod 600 /etc/cluster-agent/*.key
CERTS

    # --- Build and load kernel module ---
    log "Building lock_etcd kernel module..."
    ssh $SSH_OPTS "ec2-user@$ip" <<KMOD
set -e
# Copy the kernel module source
# (In production, package as DKMS or RPM)
echo "Kernel: \$(uname -r)"
echo "Headers: \$(ls /lib/modules/\$(uname -r)/build/include/linux/version.h 2>/dev/null && echo OK || echo MISSING)"
KMOD

    # Push kernel module source and build
    log "Syncing kernel source..."
    rsync -avz -e "ssh $SSH_OPTS" \
        --exclude='*.o' --exclude='*.ko' --exclude='*.mod*' \
        --exclude='.git' \
        "$PROJECT_ROOT/kernel/" "ec2-user@$ip:/tmp/lock_etcd_kernel/"

    ssh $SSH_OPTS "ec2-user@$ip" <<'BUILD_MOD'
set -e
cd /tmp/lock_etcd_kernel

# The shared header (letcd_netlink.h) is symlinked from pkg/protocol/
# Ensure it's available
if [[ ! -f letcd_netlink.h ]]; then
    echo "ERROR: letcd_netlink.h not found" >&2
    exit 1
fi

make -C /lib/modules/$(uname -r)/build M=$(pwd) modules 2>&1 | tail -5

if [[ -f lock_etcd.ko ]]; then
    echo "Module built: $(ls -lh lock_etcd.ko)"
else
    echo "ERROR: module build failed"
    exit 1
fi

# Load the module
sudo insmod lock_etcd.ko
lsmod | grep lock_etcd || echo "WARNING: module not in lsmod"

# Verify netlink socket
cat /proc/net/netlink | grep -P '^31\b' && echo "Netlink family 31 registered" || true
BUILD_MOD

    # --- Push and start cluster-agent ---
    log "Installing cluster-agent..."
    scp $SSH_OPTS "$PROJECT_ROOT/bin/cluster-agent" "ec2-user@$ip:/tmp/"

    ssh $SSH_OPTS "ec2-user@$ip" <<AGENT
set -e
sudo mv /tmp/cluster-agent /usr/local/bin/
sudo chmod 755 /usr/local/bin/cluster-agent

# Create systemd unit
sudo tee /etc/systemd/system/cluster-agent.service > /dev/null <<'EOF'
[Unit]
Description=GFS2 Cluster Agent (etcd-backed)
After=network-online.target
Wants=network-online.target

[Service]
ExecStart=/usr/local/bin/cluster-agent \\
  --node-id=NODE_ID_PLACEHOLDER \\
  --etcd-endpoints=ETCD_ENDPOINTS_PLACEHOLDER \\
  --etcd-cert=/etc/cluster-agent/client.crt \\
  --etcd-key=/etc/cluster-agent/client.key \\
  --etcd-ca=/etc/cluster-agent/ca.crt \\
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
sudo sed -i "s/VOL_ID_PLACEHOLDER/${VOL_ID}/" /etc/systemd/system/cluster-agent.service
sudo sed -i "s/CLUSTER_PLACEHOLDER/${CLUSTER}/" /etc/systemd/system/cluster-agent.service
sudo sed -i "s/AZ_PLACEHOLDER/${AZ}/" /etc/systemd/system/cluster-agent.service

sudo systemctl daemon-reload
sudo systemctl enable cluster-agent
sudo systemctl restart cluster-agent
sleep 3
sudo systemctl status cluster-agent --no-pager | head -10
AGENT

    # --- Format GFS2 (first node only) ---
    if $FIRST_NODE; then
        log "=== First node: formatting GFS2 ==="

        # Wait for agent to register in etcd
        sleep 5

        ssh $SSH_OPTS "ec2-user@$ip" <<FORMAT
set -e

# Find the EBS device (usually /dev/nvme1n1 or /dev/sdf)
EBS_DEV=\$(lsblk -o NAME,SERIAL | grep vol${VOL_ID#vol-} | awk '{print "/dev/"\$1}' | head -1)
if [[ -z "\$EBS_DEV" ]]; then
    # Try common names
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

        # Wait for first node to finish formatting
        sleep 10

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
log "=== All compute nodes ready ==="
log "Run: ./scripts/infra/run-full-test.sh"
