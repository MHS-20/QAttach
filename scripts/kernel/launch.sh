#!/bin/bash
# launch.sh — build custom kernel with lock_etcd on an EC2 builder instance.
#
# Env overrides:
#   QATTACH_BUILDER_AMI        Builder AMI (default: ami-05cbf8a8aa4e4b755)
#   QATTACH_BUILDER_INSTANCE   Builder instance type (default: m8i.4xlarge)
#   AWS_DEFAULT_REGION         Region (default: eu-west-1)
#   QATTACH_KEY_NAME           EC2 key pair (default: muhamad-keypair)
#   QATTACH_PEM_PATH           SSH key path (default: ~/.ssh/id_ed25519)
#   QATTACH_SUBNET             Subnet ID for builder (default: subnet-6570782d)
#   QATTACH_SG                 Security group for builder (default: sg-c56ee982)
#   QATTACH_S3_BUCKET          S3 bucket for archive (default: s3://muhamad-...)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$PROJECT_ROOT"

AMI_ID="${QATTACH_BUILDER_AMI:-ami-05cbf8a8aa4e4b755}"
INSTANCE_TYPE="${QATTACH_BUILDER_INSTANCE:-m8i.4xlarge}"
REGION="${AWS_DEFAULT_REGION:-eu-west-1}"
KEY_NAME="${QATTACH_KEY_NAME:-muhamad-keypair}"
SSH_KEY_PATH="${QATTACH_PEM_PATH:-$HOME/.ssh/id_ed25519}"
SSH_USER="ec2-user"
S3_BUCKET="${QATTACH_S3_BUCKET:-s3://muhamad-tirocinio-bucket-861507897222-eu-west-1-an}"
SUBNET_ID="${QATTACH_SUBNET:-subnet-6570782d}"
SG_ID="${QATTACH_SG:-sg-c56ee982}"

INSTANCE_ID=""

cleanup() {
    if [[ -n "$INSTANCE_ID" ]]; then
        echo "Cleaning up builder instance $INSTANCE_ID..."
        aws ec2 terminate-instances --region "$REGION" --instance-ids "$INSTANCE_ID" 2>/dev/null || true
        aws ec2 wait instance-terminated --region "$REGION" --instance-ids "$INSTANCE_ID" 2>/dev/null || true
    fi
}
trap cleanup EXIT

log() { echo "[$(date +%T)] $*"; }

SSH_CMD="ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 -o BatchMode=yes -i $SSH_KEY_PATH"

wait_for_ssh() {
    local ip="$1" max="${2:-60}" i=0
    while [[ $i -lt $max ]]; do
        if $SSH_CMD "${SSH_USER}@${ip}" "echo ok" &>/dev/null; then
            return 0
        fi
        i=$((i + 1))
        sleep 5
    done
    echo "ERROR: SSH timeout after $((max * 5))s" >&2
    return 1
}

run() {
    local CMD="$1"
    log "Remote: ${CMD:0:100}..."
    $SSH_CMD "${SSH_USER}@${PUBLIC_IP}" "sudo bash -s" <<< "$CMD" 2>&1
}

run_user() {
    local CMD="$1"
    log "Remote: ${CMD:0:100}..."
    $SSH_CMD "${SSH_USER}@${PUBLIC_IP}" "bash -s" <<< "$CMD" 2>&1
}

# ---- Launch builder instance ----

log "=== Launching kernel builder ==="
log "AMI: $AMI_ID  Type: $INSTANCE_TYPE  Region: $REGION"

INSTANCE_ID=$(aws ec2 run-instances \
  --region "$REGION" \
  --image-id "$AMI_ID" \
  --instance-type "$INSTANCE_TYPE" \
  --key-name "$KEY_NAME" \
  --subnet-id "$SUBNET_ID" \
  --security-group-ids "$SG_ID" \
  --block-device-mappings '[{"DeviceName":"/dev/xvda","Ebs":{"VolumeSize":30,"VolumeType":"gp3"}}]' \
  --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=kernel-builder}]" \
  --query 'Instances[0].InstanceId' \
  --output text)

log "Instance: $INSTANCE_ID"

log "Waiting for instance running..."
aws ec2 wait instance-running --region "$REGION" --instance-ids "$INSTANCE_ID"

PUBLIC_IP=$(aws ec2 describe-instances \
  --region "$REGION" \
  --instance-ids "$INSTANCE_ID" \
  --query 'Reservations[0].Instances[0].PublicIpAddress' \
  --output text)

log "Public IP: $PUBLIC_IP"

log "Waiting for SSH..."
wait_for_ssh "$PUBLIC_IP"
log "SSH ready"

# ---- Install build dependencies ----

log "=== Installing build dependencies ==="

run "dnf groupinstall 'Development Tools' -y"
run "dnf install -y openssl-devel elfutils-libelf-devel bc flex bison perl ncurses-devel dwarves rsync wget git hmaccalc python3-devel perl-generators perl-ExtUtils-Embed dnf-utils"

# ---- Download kernel source ----

log "=== Downloading kernel source ==="

KERNEL_VERSION=$($SSH_CMD "${SSH_USER}@${PUBLIC_IP}" "uname -r")
log "Stock kernel: $KERNEL_VERSION"

run_user "cd /tmp && dnf download --source kernel6.18"
run_user "cd /tmp && rpm -ivh kernel6.18*.src.rpm"
run "dnf builddep -y /home/ec2-user/rpmbuild/SPECS/kernel6.18.spec"
run_user "cd ~/rpmbuild/SPECS && rpmbuild -bp --target=\$(uname -m) kernel6.18.spec"

# ---- Configure kernel ----

log "=== Configuring kernel ==="

run_user "cd ~/rpmbuild/BUILD/kernel-*/linux-*/ && cp /boot/config-\$(uname -r) .config && make olddefconfig"

run_user "cd ~/rpmbuild/BUILD/kernel-*/linux-*/ && \
  ./scripts/config --module CONFIG_GFS2_FS && \
  ./scripts/config --enable CONFIG_DLM && \
  ./scripts/config --module CONFIG_DLM_LOCK_DLM && \
  ./scripts/config --enable CONFIG_GFS2_FS_LOCKING_DLM && \
  ./scripts/config --enable CONFIG_CONFIGFS_FS && \
  ./scripts/config --enable CONFIG_SYSFS && \
  ./scripts/config --enable CONFIG_DLM_DEBUG"

run_user "cd ~/rpmbuild/BUILD/kernel-*/linux-*/ && \
  ./scripts/config --set-val CONFIG_AMAZON_ENA_ETHERNET y && \
  ./scripts/config --set-val CONFIG_NVME_CORE y && \
  ./scripts/config --set-val CONFIG_BLK_DEV_NVME y"

run_user "cd ~/rpmbuild/BUILD/kernel-*/linux-*/ && \
  ./scripts/config --disable CONFIG_MODULE_SIG_FORCE"

run_user "cd ~/rpmbuild/BUILD/kernel-*/linux-*/ && make olddefconfig"

# olddefconfig may revert NVMe. Force it back and accept dependencies.
run_user "cd ~/rpmbuild/BUILD/kernel-*/linux-*/ && \
  sed -i 's/.*CONFIG_NVME_CORE.*/CONFIG_NVME_CORE=y/' .config && \
  sed -i 's/.*CONFIG_BLK_DEV_NVME.*/CONFIG_BLK_DEV_NVME=y/' .config && \
  yes '' | make oldconfig 2>&1 | tail -1"

log "=== Verifying NVMe ==="
run_user "cd ~/rpmbuild/BUILD/kernel-*/linux-*/ && grep -E 'CONFIG_NVME_CORE|CONFIG_BLK_DEV_NVME' .config"

# ---- Integrate lock_etcd into kernel tree ----

log "=== Integrating lock_etcd ==="

scp -i "$SSH_KEY_PATH" -o StrictHostKeyChecking=no -o BatchMode=yes \
  kernel/lock_etcd_main.c kernel/lock_etcd_netlink.c kernel/lock_etcd_glock.c \
  kernel/lock_etcd_mount.c kernel/lock_etcd_lock.c kernel/lock_etcd_internal.h \
  pkg/protocol/letcd_netlink.h scripts/kernel/patch-kernel.py \
  "${SSH_USER}@${PUBLIC_IP}:/home/${SSH_USER}/"

run_user "
SRC=\$(echo ~/rpmbuild/BUILD/kernel-*/linux-*/)
GFS2=\${SRC}fs/gfs2

cp ~/lock_etcd_main.c ~/lock_etcd_netlink.c ~/lock_etcd_glock.c \
   ~/lock_etcd_mount.c ~/lock_etcd_lock.c \
   ~/lock_etcd_internal.h ~/letcd_netlink.h \"\$GFS2/\"
echo 'Copied lock_etcd sources'

cat >> \"\$GFS2/Kconfig\" << 'KEOF'

config GFS2_FS_LOCKING_ETCD
	bool \"GFS2 etcd-backed locking (lock_etcd)\"
	depends on GFS2_FS
	help
	  Enable the lock_etcd locking protocol for GFS2.
KEOF

cat >> \"\$GFS2/Makefile\" << 'MEOF'
gfs2-\$(CONFIG_GFS2_FS_LOCKING_ETCD) += lock_etcd_main.o lock_etcd_netlink.o lock_etcd_glock.o lock_etcd_mount.o lock_etcd_lock.o
MEOF

cd \"\$SRC\"
./scripts/config --enable CONFIG_GFS2_FS_LOCKING_ETCD
make olddefconfig
echo 'Enabled CONFIG_GFS2_FS_LOCKING_ETCD'

python3 ~/patch-kernel.py \"\$SRC\"

grep CONFIG_GFS2_FS_LOCKING .config
"

# ---- Compile kernel ----

log "=== Compiling kernel ==="

run_user "cd ~/rpmbuild/BUILD/kernel-*/linux-*/ && make -j\$(nproc) 2>&1 | tee /tmp/build.log"
run_user "cd ~/rpmbuild/BUILD/kernel-*/linux-*/ && make -j\$(nproc) M=fs/gfs2 M=fs/dlm 2>&1"

# ---- Build gfs2-utils ----

log "=== Building gfs2-utils ==="

run_user "
cd /tmp
sudo dnf install -y \
  autoconf automake libtool \
  ncurses-devel gettext \
  zlib-devel bzip2-devel \
  libblkid-devel libuuid-devel \
  corosynclib-devel libqb-devel \
  systemd-devel libxml2-devel \
  readline-devel 2>&1 | tail -2
git clone https://pagure.io/gfs2-utils.git 2>&1 | tail -1
cd gfs2-utils
./autogen.sh 2>&1 | tail -1
./configure --prefix=/usr --sbindir=/usr/sbin --sysconfdir=/etc 2>&1 | tail -2
make -j\$(nproc) 2>&1 | tail -2
sudo make install 2>&1 | tail -2
ls /usr/sbin/mkfs.gfs2 && echo 'gfs2-utils built'
"

# ---- Install modules and package ----

log "=== Installing modules and packaging ==="

run "cd /home/${SSH_USER}/rpmbuild/BUILD/kernel-*/linux-*/ && make modules_install"
run "cd /home/${SSH_USER}/rpmbuild/BUILD/kernel-*/linux-*/ && make install"

KERNEL_RELEASE=$($SSH_CMD "${SSH_USER}@${PUBLIC_IP}" \
  "cd /home/${SSH_USER}/rpmbuild/BUILD/kernel-*/linux-*/ && make kernelrelease")

log "Kernel release: $KERNEL_RELEASE"

run "dracut --force /boot/initramfs-${KERNEL_RELEASE}.img ${KERNEL_RELEASE}"
run "mv /boot/vmlinuz /boot/vmlinuz-${KERNEL_RELEASE}-custom"
run "mv /boot/initramfs-${KERNEL_RELEASE}.img /boot/initramfs-${KERNEL_RELEASE}-custom.img"

run "grubby --add-kernel=/boot/vmlinuz-${KERNEL_RELEASE}-custom --initrd=/boot/initramfs-${KERNEL_RELEASE}-custom.img --title='Linux ${KERNEL_RELEASE} custom (lock_etcd)' --copy-default --make-default || true"

# ---- Package artifacts ----

log "=== Packaging ==="

ARCHIVE="kernel-${KERNEL_RELEASE}-custom.tar.gz"

run_user "sudo tar -czf /tmp/${ARCHIVE} \
  /boot/vmlinuz-${KERNEL_RELEASE}-custom \
  /boot/initramfs-${KERNEL_RELEASE}-custom.img \
  /lib/modules/${KERNEL_RELEASE}/ \
  /usr/sbin/mkfs.gfs2 \
  /usr/sbin/fsck.gfs2 \
  /usr/sbin/gfs2_jadd \
  /usr/sbin/gfs2_grow \
  /usr/sbin/gfs2_edit"
run "chown ${SSH_USER}:${SSH_USER} /tmp/${ARCHIVE}"

# ---- Download and upload ----

log "=== Downloading archive ==="

scp -i "$SSH_KEY_PATH" -o StrictHostKeyChecking=no -o BatchMode=yes \
  "${SSH_USER}@${PUBLIC_IP}:/tmp/${ARCHIVE}" /tmp/

log "=== Uploading to S3 ==="
aws s3 cp "/tmp/${ARCHIVE}" "${S3_BUCKET}/"

log ""
log "=== DONE ==="
log "Kernel: $KERNEL_RELEASE"
log "Archive: /tmp/${ARCHIVE}"
log "S3: ${S3_BUCKET}/${ARCHIVE}"
