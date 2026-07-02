#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/../.."

AMI_ID="ami-05cbf8a8aa4e4b755"
INSTANCE_TYPE="m8i.4xlarge"
REGION="eu-west-1"
KEY_NAME="muhamad-keypair"
SSH_KEY_PATH="$HOME/.ssh/id_ed25519"
SSH_USER="ec2-user"
IAM_PROFILE="ec2-fencing-test"
S3_BUCKET="s3://muhamad-tirocinio-bucket-861507897222-eu-west-1-an"

echo "========================================"
echo " Launching kernel build instance..."
echo "========================================"

INSTANCE_ID=$(aws ec2 run-instances \
  --region "$REGION" \
  --image-id "$AMI_ID" \
  --instance-type "$INSTANCE_TYPE" \
  --key-name "$KEY_NAME" \
  --subnet-id subnet-6570782d \
  --security-group-ids sg-c56ee982 \
  --block-device-mappings '[{"DeviceName":"/dev/xvda","Ebs":{"VolumeSize":30,"VolumeType":"gp3"}}]' \
  --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=kernel-builder}]" \
  --query 'Instances[0].InstanceId' \
  --output text)

echo "Instance ID: $INSTANCE_ID"

echo "Waiting for instance to reach 'running' state..."
aws ec2 wait instance-running --region "$REGION" --instance-ids "$INSTANCE_ID"

PUBLIC_IP=$(aws ec2 describe-instances \
  --region "$REGION" \
  --instance-ids "$INSTANCE_ID" \
  --query 'Reservations[0].Instances[0].PublicIpAddress' \
  --output text)

echo "Public IP: $PUBLIC_IP"

echo ""
echo "Waiting for SSH..."
until ssh -i "$SSH_KEY_PATH" \
  -o StrictHostKeyChecking=no \
  -o ConnectTimeout=5 \
  -o BatchMode=yes \
  "${SSH_USER}@${PUBLIC_IP}" "echo ok" &>/dev/null; do
  echo -n "."
  sleep 5
done
echo " ready"

run() {
  local CMD="$1"
  echo "[instance] Running: ${CMD:0:80}..."
  ssh -i "$SSH_KEY_PATH" \
    -o StrictHostKeyChecking=no \
    -o BatchMode=yes \
    "${SSH_USER}@${PUBLIC_IP}" "sudo bash -s" <<< "$CMD" 2>&1
}

run_user() {
  local CMD="$1"
  echo "[instance] Running: ${CMD:0:80}..."
  ssh -i "$SSH_KEY_PATH" \
    -o StrictHostKeyChecking=no \
    -o BatchMode=yes \
    "${SSH_USER}@${PUBLIC_IP}" "bash -s" <<< "$CMD" 2>&1
}

echo ""
echo "========================================"
echo " Installing build dependencies..."
echo "========================================"

run "dnf groupinstall 'Development Tools' -y"
run "dnf install -y openssl-devel elfutils-libelf-devel bc flex bison perl ncurses-devel dwarves rsync wget git hmaccalc python3-devel perl-generators perl-ExtUtils-Embed dnf-utils"

echo ""
echo "========================================"
echo " Downloading kernel source..."
echo "========================================"

KERNEL_VERSION=$(ssh -i "$SSH_KEY_PATH" \
  -o StrictHostKeyChecking=no \
  -o BatchMode=yes \
  "${SSH_USER}@${PUBLIC_IP}" "uname -r")
echo "Stock kernel version: $KERNEL_VERSION"

run_user "cd /tmp && dnf download --source kernel6.18"
run_user "cd /tmp && rpm -ivh kernel6.18*.src.rpm"
run "dnf builddep -y /home/ec2-user/rpmbuild/SPECS/kernel6.18.spec"
run_user "cd ~/rpmbuild/SPECS && rpmbuild -bp --target=\$(uname -m) kernel6.18.spec"

echo ""
echo "========================================"
echo " Configuring kernel..."
echo "========================================"

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

run_user "cd ~/rpmbuild/BUILD/kernel-*/linux-*/ && grep -E 'CONFIG_GFS2|CONFIG_DLM' .config"

echo ""
echo "========================================"
echo " Integrating lock_etcd into kernel tree..."
echo "========================================"

# Copy lock_etcd sources and patch script to the build instance
scp -i "$SSH_KEY_PATH" -o StrictHostKeyChecking=no -o BatchMode=yes \
  kernel/lock_etcd_main.c kernel/lock_etcd_netlink.c kernel/lock_etcd_glock.c \
  kernel/lock_etcd_mount.c kernel/lock_etcd_lock.c kernel/lock_etcd_internal.h \
  pkg/protocol/letcd_netlink.h scripts/kernel/patch-kernel.py \
  "${SSH_USER}@${PUBLIC_IP}:/home/${SSH_USER}/"

run_user "
SRC=\$(echo ~/rpmbuild/BUILD/kernel-*/linux-*/)
GFS2=\${SRC}fs/gfs2

# Copy lock_etcd source files into kernel tree
cp ~/lock_etcd_main.c ~/lock_etcd_netlink.c ~/lock_etcd_glock.c \
   ~/lock_etcd_mount.c ~/lock_etcd_lock.c \
   ~/lock_etcd_internal.h ~/letcd_netlink.h \"\$GFS2/\"
echo 'Copied lock_etcd sources'

# Add Kconfig entry
cat >> \"\$GFS2/Kconfig\" << 'KEOF'

config GFS2_FS_LOCKING_ETCD
	bool \"GFS2 etcd-backed locking (lock_etcd)\"
	depends on GFS2_FS
	help
	  Enable the lock_etcd locking protocol for GFS2.
KEOF

# Add Makefile entries
cat >> \"\$GFS2/Makefile\" << 'MEOF'
gfs2-\$(CONFIG_GFS2_FS_LOCKING_ETCD) += lock_etcd_main.o lock_etcd_netlink.o lock_etcd_glock.o lock_etcd_mount.o lock_etcd_lock.o
MEOF

# Enable the config
cd \"\$SRC\"
./scripts/config --enable CONFIG_GFS2_FS_LOCKING_ETCD
make olddefconfig
echo 'Enabled CONFIG_GFS2_FS_LOCKING_ETCD'

# Patch main.c and ops_fstype.c for lock_etcd registration
python3 ~/patch-kernel.py \"\$SRC\"

grep CONFIG_GFS2_FS_LOCKING .config
"

echo ""
echo "========================================"
echo " Compiling kernel (this takes a while)..."
echo "========================================"

run_user "cd ~/rpmbuild/BUILD/kernel-*/linux-*/ && make -j\$(nproc) 2>&1 | tee /tmp/build.log"
run_user "cd ~/rpmbuild/BUILD/kernel-*/linux-*/ && make -j\$(nproc) M=fs/gfs2 M=fs/dlm 2>&1"

echo ""
echo "========================================"
echo " Building gfs2-utils (userspace tools)..."
echo "========================================"

run_user "
# Build gfs2-utils from source (pagure.io, per SetUpAL2023.md)
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

echo ""
echo "========================================"
echo " Installing modules and packaging..."
echo "========================================"

run "cd /home/${SSH_USER}/rpmbuild/BUILD/kernel-*/linux-*/ && make modules_install"
run "cd /home/${SSH_USER}/rpmbuild/BUILD/kernel-*/linux-*/ && make install"

KERNEL_RELEASE=$(ssh -i "$SSH_KEY_PATH" \
  -o StrictHostKeyChecking=no \
  -o BatchMode=yes \
  "${SSH_USER}@${PUBLIC_IP}" \
  "cd /home/${SSH_USER}/rpmbuild/BUILD/kernel-*/linux-*/ && make kernelrelease")

echo "Kernel release: $KERNEL_RELEASE"

run "dracut --force /boot/initramfs-${KERNEL_RELEASE}.img ${KERNEL_RELEASE}"
run "mv /boot/vmlinuz /boot/vmlinuz-${KERNEL_RELEASE}-custom"
run "mv /boot/initramfs-${KERNEL_RELEASE}.img /boot/initramfs-${KERNEL_RELEASE}-custom.img"

run "grubby --add-kernel=/boot/vmlinuz-${KERNEL_RELEASE}-custom --initrd=/boot/initramfs-${KERNEL_RELEASE}-custom.img --title='Linux ${KERNEL_RELEASE} custom (GFS2+DLM)' --copy-default --make-default || true"

echo ""
echo "========================================"
echo " Packaging kernel artifacts..."
echo "========================================"

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

echo ""
echo "========================================"
echo " Downloading and uploading to S3..."
echo "========================================"

scp -i "$SSH_KEY_PATH" -o StrictHostKeyChecking=no -o BatchMode=yes \
  "${SSH_USER}@${PUBLIC_IP}:/tmp/${ARCHIVE}" /tmp/

aws s3 cp "/tmp/${ARCHIVE}" "${S3_BUCKET}/"
rm -f "/tmp/${ARCHIVE}"

echo ""
echo "Upload complete: ${S3_BUCKET}/${ARCHIVE}"

echo ""
echo "========================================"
echo " DONE"
echo "========================================"
echo "Kernel: $KERNEL_RELEASE"
echo "Archive: ${S3_BUCKET}/${ARCHIVE}"
echo ""
echo "To use this kernel in AL2023/launch_cluster.sh, update:"
echo "  KERNEL_VERSION=\"$KERNEL_RELEASE\""
echo "  KERNEL_FILE=\"kernel-${KERNEL_RELEASE}-custom.tar.gz\""
