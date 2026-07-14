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

# Auto-discover latest custom kernel tarball
if [[ -z "$LOCAL_TARBALL" ]]; then
    log "Discovering latest kernel from S3..."
    KERNEL_FILE=$(aws s3 ls "${S3_BUCKET}/" --region "${REGION}" 2>/dev/null \
        | grep 'kernel-.*-custom.tar.gz' \
        | sort -r | head -1 | awk '{print $NF}')
    if [[ -z "$KERNEL_FILE" ]]; then
        die "No custom kernel tarball found in ${S3_BUCKET}. Run scripts/kernel/launch.sh first."
    fi
    log "  Found: ${KERNEL_FILE}"
else
    KERNEL_FILE=$(basename "$LOCAL_TARBALL")
fi

S3_URL="${S3_BUCKET}/${KERNEL_FILE}"
S3_HTTP_URL="https://$(echo "${S3_BUCKET#s3://}" | sed 's|/.*||').s3.${REGION}.amazonaws.com/${KERNEL_FILE}"
SSH_CMD="ssh $SSH_OPTS"

log "=== Deploying custom kernel ==="
log "Nodes: ${IPS[*]}"

# ---- Upload tarball to each node ----

for ip in "${IPS[@]}"; do
    log "--- Setting up $ip ---"

    if [[ -n "$LOCAL_TARBALL" ]]; then
        log "Uploading tarball to $ip..."
        scp $SSH_OPTS "$LOCAL_TARBALL" "ec2-user@${ip}:/tmp/${KERNEL_FILE}"
        # Verify upload with local checksum
        LOCAL_SHA=$(sha256sum "$LOCAL_TARBALL" | awk '{print $1}')
        REMOTE_SHA=$($SSH_CMD "ec2-user@${ip}" "sha256sum /tmp/${KERNEL_FILE}" 2>/dev/null | awk '{print $1}')
        if [[ "$LOCAL_SHA" != "$REMOTE_SHA" ]]; then
            die "Checksum mismatch on $ip (local=$LOCAL_SHA remote=$REMOTE_SHA)"
        fi
        log "  upload verified (sha256 ok)"
    else
        log "Downloading kernel from S3 on $ip..."
        $SSH_CMD "ec2-user@${ip}" "
set -e
cd /tmp
# Compute nodes have no IAM role, so aws s3 cp will fail.
# The tarball must be uploaded via --local-tarball instead.
if ! aws s3 cp '${S3_URL}' /tmp/${KERNEL_FILE} 2>/dev/null; then
    if ! curl -sIf '${S3_HTTP_URL}' >/dev/null 2>&1; then
        echo 'ERROR: S3 bucket is not publicly accessible.'
        echo 'Use --local-tarball to deploy from a local file:'
        echo '  ./deploy-kernel.sh --local-tarball /tmp/kernel-...-custom.tar.gz <ips>'
        exit 1
    fi
    curl -sLo '${KERNEL_FILE}' '${S3_HTTP_URL}'
fi
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
CUSTOM_VMLINUZ=\$(ls /boot/vmlinuz-*-custom 2>/dev/null | head -1)
if [[ -z \"\$CUSTOM_VMLINUZ\" ]]; then
    echo 'ERROR: no custom vmlinuz found'
    exit 1
fi

# Verify kernel DOS magic (MZ)
VMLINUZ_MAGIC=\$(hexdump -n 2 -e '2/1 \"%c\"' \"\$CUSTOM_VMLINUZ\" 2>/dev/null)
if [[ \"\$VMLINUZ_MAGIC\" != 'MZ' ]]; then
    echo \"ERROR: vmlinuz magic is '\$VMLINUZ_MAGIC' (expected 'MZ') — file is corrupt\"
    ls -la \"\$CUSTOM_VMLINUZ\"
    exit 1
fi
echo \"Custom vmlinuz: \$CUSTOM_VMLINUZ (\$(du -h \"\$CUSTOM_VMLINUZ\" | cut -f1)) magic OK\"

CUSTOM_INITRD=\$(ls /boot/initramfs-*-custom.img 2>/dev/null | head -1)
if [[ -z \"\$CUSTOM_INITRD\" ]]; then
    echo 'ERROR: no custom initrd found'
    exit 1
fi
echo \"Custom initrd: \$CUSTOM_INITRD (\$(du -h \"\$CUSTOM_INITRD\" | cut -f1))\"

# Set default kernel with grubby
sudo grubby --info=\"\$CUSTOM_VMLINUZ\" >/dev/null 2>&1 || \
    sudo grubby --add-kernel=\"\$CUSTOM_VMLINUZ\" --initrd=\"\$CUSTOM_INITRD\" --title='Custom lock_etcd kernel' --copy-default
sudo grubby --set-default=\"\$CUSTOM_VMLINUZ\"
echo 'Default kernel set'

# Prevent stale etcd from auto-starting after reboot with old certs/config.
sudo systemctl stop etcd 2>/dev/null || true
sudo systemctl disable etcd 2>/dev/null || true
sudo rm -rf /var/lib/etcd /etc/systemd/system/etcd.service.d
echo 'Stale etcd cleaned'

echo 'Rebooting...'
sudo reboot
" 2>/dev/null || true   # reboot kills SSH — exit code is meaningless
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

# After all nodes are up, run depmod on custom kernel so modprobe works
for ip in "${IPS[@]}"; do
    $SSH_CMD "ec2-user@${ip}" "sudo depmod -a \$(uname -r) 2>/dev/null || sudo depmod -a" 2>/dev/null || true
done
log "depmod run on all nodes"

log "=== All nodes rebooted with custom kernel ==="
