#!/bin/bash
# deploy-kernel.sh — install custom kernel on compute nodes.
#
# Usage:
#   ./deploy-kernel.sh [--local-tarball <path>] <ip1> [ip2 ...]
#   ./deploy-kernel.sh <ip1> [ip2 ...]                    # downloads from S3
#
# Env: QATTACH_PEM_PATH, AWS_DEFAULT_REGION (via state.sh)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/state.sh"

LOCAL_TARBALL=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --local-tarball) LOCAL_TARBALL="$2"; shift 2 ;;
        *) break ;;
    esac
done

if [[ $# -eq 0 ]]; then
    die "Usage: $0 [--local-tarball <path>] <ip1> [ip2 ...]"
fi

IPS=("$@")
S3_URL="${S3_BUCKET}/kernel-6.18.35-custom.tar.gz"
KERNEL_FILE="kernel-6.18.35-custom.tar.gz"
SSH_CMD="ssh $SSH_OPTS"

log "=== Deploying custom kernel ==="
log "Nodes: ${IPS[*]}"

# ---- Upload tarball to each node ----

for ip in "${IPS[@]}"; do
    log "--- Setting up $ip ---"

    if [[ -n "$LOCAL_TARBALL" ]]; then
        log "Uploading tarball to $ip..."
        scp $SSH_OPTS "$LOCAL_TARBALL" "ec2-user@${ip}:/tmp/${KERNEL_FILE}"
    else
        log "Downloading kernel from S3 on $ip..."
        $SSH_CMD "ec2-user@${ip}" "
set -e
cd /tmp
aws s3 cp '${S3_URL}' /tmp/${KERNEL_FILE} 2>/dev/null || \
  curl -sLo '${KERNEL_FILE}' 'https://muhamad-tirocinio-bucket-861507897222-eu-west-1-an.s3.eu-west-1.amazonaws.com/${KERNEL_FILE}'
ls -lh /tmp/${KERNEL_FILE}
" || { log "ERROR: failed to download kernel on $ip"; exit 1; }
    fi
done

# ---- Extract, configure, and reboot each node ----

for ip in "${IPS[@]}"; do
    log "--- Installing kernel on $ip ---"
    $SSH_CMD "ec2-user@${ip}" "
set -e
cd /tmp

echo 'Extracting kernel...'
sudo tar xzf /tmp/${KERNEL_FILE} -C /
rm -f /tmp/${KERNEL_FILE}

echo 'Verifying extracted files...'
ls -la /boot/vmlinuz-*custom* 2>/dev/null || { echo 'ERROR: no custom vmlinuz'; exit 1; }

# Find the custom kernel vmlinuz (has -custom suffix)
CUSTOM_VMLINUZ=\$(ls /boot/vmlinuz-*-custom 2>/dev/null | head -1)
if [[ -z \"\$CUSTOM_VMLINUZ\" ]]; then
    echo 'ERROR: no custom vmlinuz found'
    exit 1
fi
echo \"Custom vmlinuz: \$CUSTOM_VMLINUZ\"

# Find matching initramfs
CUSTOM_INITRD=\$(ls /boot/initramfs-*-custom.img 2>/dev/null | head -1)
echo \"Custom initrd: \$CUSTOM_INITRD\"

# Find the modules directory (custom kernel modules from the tarball)
KVER=\$(ls -d /lib/modules/*/ 2>/dev/null | head -1 | xargs basename)
echo \"Kernel modules: \$KVER\"

# Set default kernel with grubby
sudo grubby --info=\"\$CUSTOM_VMLINUZ\" >/dev/null 2>&1 || \
    sudo grubby --add-kernel=\"\$CUSTOM_VMLINUZ\" --initrd=\"\$CUSTOM_INITRD\" --title=\"Custom \$KVER (lock_etcd)\" --copy-default
sudo grubby --set-default=\"\$CUSTOM_VMLINUZ\"
echo \"Default kernel set: \$CUSTOM_VMLINUZ\"

echo 'Rebooting...'
sudo reboot
" 2>/dev/null || true
done

# ---- Wait for all nodes to reboot and come back ----

log "Waiting 15s for nodes to reboot..."
sleep 15

for ip in "${IPS[@]}"; do
    log "Waiting for $ip..."
    for i in $(seq 1 40); do
        if $SSH_CMD -o ConnectTimeout=5 "ec2-user@${ip}" "uname -r" 2>/dev/null | grep -q "6.18"; then
            KVER=$($SSH_CMD "ec2-user@${ip}" "uname -r")
            log "  $ip is up: $KVER"
            break
        fi
        if [[ $i -eq 40 ]]; then
            log "ERROR: $ip did not come back after reboot"
            exit 1
        fi
        sleep 5
    done
done

log "=== All nodes rebooted with custom kernel ==="
