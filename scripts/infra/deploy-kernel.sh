#!/bin/bash
# deploy-kernel.sh — install custom kernel with GFS2+lock_etcd on compute nodes.
#
# Downloads the kernel archive from S3, extracts to /boot + /lib/modules,
# updates grub, and reboots.
#
# Usage: ./deploy-kernel.sh <ip1> <ip2> ...
#
# Env: S3_KERNEL_URL (default: s3://muhamad-tirocinio-bucket-.../kernel-6.18.35-custom.tar.gz)

set -euo pipefail
PEM="${QATTACH_PEM_PATH:-$HOME/.ssh/id_ed25519}"
PEM="${PEM/#\~/$HOME}"
SSH="ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 -i $PEM"
KERNEL_URL="${S3_KERNEL_URL:-s3://muhamad-tirocinio-bucket-861507897222-eu-west-1-an/kernel-6.18.35-custom.tar.gz}"
KERNEL_FILE="$(basename "$KERNEL_URL")"

log() { echo "[$(date +%T)] $*"; }

if [[ $# -eq 0 ]]; then
    echo "Usage: $0 <ip1> [ip2 ...]"
    exit 1
fi

for IP in "$@"; do
    log "=== Deploying custom kernel to $IP ==="

    # Download from S3 (instance needs S3 access via IAM role or instance profile)
    $SSH "ec2-user@$IP" "
set -e
cd /tmp
echo 'Downloading kernel...'
aws s3 cp '$KERNEL_URL' /tmp/ 2>/dev/null || { echo 'aws s3 failed, trying curl...'; curl -sLO 'https://muhamad-tirocinio-bucket-861507897222-eu-west-1-an.s3.eu-west-1.amazonaws.com/$KERNEL_FILE'; }
ls -lh /tmp/$KERNEL_FILE
echo 'Extracting...'
sudo tar xzf /tmp/$KERNEL_FILE -C /
rm -f /tmp/$KERNEL_FILE

# Install gfs2-utils (if included in archive)
for bin in mkfs.gfs2 mount.gfs2 fsck.gfs2 gfs2_jadd gfs2_grow gfs2_edit; do
    if [[ -f /usr/sbin/\$bin ]]; then
        sudo chmod 755 /usr/sbin/\$bin
    fi
done
which mkfs.gfs2 2>/dev/null || echo '(mkfs.gfs2 not in archive — will be built by setup-compute.sh)'

# Verify extracted files
ls -la /boot/vmlinuz-*custom* 2>/dev/null || echo 'WARN: no custom vmlinuz'
ls /lib/modules/*custom*/kernel/fs/gfs2/gfs2.ko 2>/dev/null || ls /lib/modules/*/kernel/fs/gfs2/gfs2.ko 2>/dev/null

# Set default kernel
KVER=\$(ls -d /lib/modules/6.18.*/ 2>/dev/null | head -1 | xargs basename)
if [[ -n \"\$KVER\" ]]; then
    echo \"Found custom kernel: \$KVER\"
    sudo grubby --set-default /boot/vmlinuz-\${KVER}-custom 2>/dev/null || \
    sudo grubby --set-default /boot/vmlinuz-\${KVER} 2>/dev/null || true
fi

echo 'Rebooting into custom kernel...'
sudo reboot
" 2>&1 | grep -v WARNING | grep -v "vulnerable\|decrypt\|server may\|Permanently" &

done

wait

log "All nodes rebooting. Waiting 30s for them to come back..."
sleep 30

for IP in "$@"; do
    log "Waiting for $IP to reboot..."
    for i in $(seq 1 20); do
        if $SSH -o ConnectTimeout=5 "ec2-user@$IP" "uname -r" 2>/dev/null | grep -q "6.18"; then
            KVER=$($SSH "ec2-user@$IP" "uname -r")
            log "  $IP is up: $KVER"
            break
        fi
        sleep 5
    done
done
