# SetUp AL2023: GFS2 + Pacemaker

## Compile the Kernel

Download build dependencies:

```bash
uname -r
cat /etc/os-release
lscpu | grep Architecture

sudo dnf groupinstall "Development Tools" -y
sudo dnf install -y \
  openssl-devel elfutils-libelf-devel bc \
  flex bison perl ncurses-devel dwarves \
  rsync wget curl git hmaccalc \
  python3-devel perl-generators perl-ExtUtils-Embed
```

Get the kernel source code:

```bash
sudo dnf install -y dnf-utils
dnf download --source kernel-$(uname -r)

rpm -ivh kernel-*.src.rpm
sudo dnf builddep -y ~/rpmbuild/SPECS/kernel.spec

cd ~/rpmbuild/SPECS
rpmbuild -bp --target=$(uname -m) kernel.spec

# Source tree lands here:
cd ~/rpmbuild/BUILD/kernel-*/linux-*/
```

Copy the running kernel configs: 

```bash
cp /boot/config-$(uname -r) .config
make olddefconfig
```

Enable GFS2 and DLM modules:

```bash
./scripts/config --module CONFIG_GFS2_FS
./scripts/config --enable CONFIG_DLM
./scripts/config --module CONFIG_DLM_LOCK_DLM
./scripts/config --enable CONFIG_GFS2_FS_LOCKING_DLM
./scripts/config --enable CONFIG_CONFIGFS_FS
./scripts/config --enable CONFIG_SYSFS
./scripts/config --enable CONFIG_DLM_DEBUG

# Re-sync to resolve any new dependencies
make olddefconfig
grep -E "CONFIG_GFS2|CONFIG_DLM" .config
```

Compile the kernel: 

```bash
make -j$(nproc) 2>&1 | tee build.log
make -j$(nproc) M=fs/gfs2 M=fs/dlm
```

Install modules and kernel: 

```bash
sudo make modules_install
sudo make install
sudo dracut --force /boot/initramfs-$(make kernelrelease).img $(make kernelrelease)

sudo mv /boot/vmlinuz /boot/vmlinuz-$(make kernelrelease)-custom
sudo mv /boot/initramfs-$(make kernelrelease).img /boot/initramfs-$(make kernelrelease)-custom.img
```

Update GRUB: 

```bash
sudo grubby --add-kernel=/boot/vmlinuz-$(make kernelrelease)-custom \
  --initrd=/boot/initramfs-$(make kernelrelease)-custom.img \
  --title="Linux $(make kernelrelease) custom (GFS2+DLM)" \
  --copy-default \
  --make-default

# Verify
sudo grubby --info=ALL | grep -E "index|kernel|title|initrd"
sudo grubby --default-kernel
```

Ensure kernel is bootable: 

```bash
# for Nitro instances
./scripts/config --enable CONFIG_AMAZON_ENA_ETHERNET
./scripts/config --enable CONFIG_NVME_CORE
./scripts/config --enable CONFIG_BLK_DEV_NVME
make olddefconfig
```

```bash
# for Xen instances
./scripts/config --enable CONFIG_XEN_BLKDEV_FRONTEND
./scripts/config --enable CONFIG_XEN_NETDEV_FRONTEND
make olddefconfig

# for Virtio instances
./scripts/config --enable CONFIG_VIRTIO_PCI
./scripts/config --enable CONFIG_VIRTIO_BLK
./scripts/config --enable CONFIG_VIRTIO_NET
make olddefconfig
```

Reboot:

```bash
sudo reboot
```

In case of signing error:

```bash
# Check if your kernel requires signed modules:
grep CONFIG_MODULE_SIG_FORCE .config

# If =y, you need to sign modules. Simplest fix for a custom build:
./scripts/config --disable CONFIG_MODULE_SIG_FORCE
./scripts/config --set-val CONFIG_MODULE_SIG all    # set to n to disable entirely
make olddefconfig
```

Verify: 

```bash
# Confirm new kernel
uname -r

# Load and verify modules
sudo modprobe gfs2
sudo modprobe dlm

lsmod | grep -E "gfs2|dlm"

# Check module info
modinfo gfs2
modinfo dlm
modinfo gfs2 | grep -E "filename|version"
modinfo dlm | grep -E "filename|version"
```

## Export & Share the Kernel

Upload the freshly compiled kernel: 

```bash
cd ~/rpmbuild/BUILD/kernel-*/linux-*/

sudo tar -czf kernel-$(make kernelrelease)-custom.tar.gz \
  /boot/vmlinuz-$(make kernelrelease)-custom \
  /boot/initramfs-$(make kernelrelease)-custom.img \
  /lib/modules/$(make kernelrelease)/
  
sudo chown ec2-user:ec2-user /tmp/kernel-$(make kernelrelease)-custom.tar.gz
  
aws s3 cp kernel-$(make kernelrelease)-custom.tar.gz s3://muhamad-tirocinio-bucket-861507897222-eu-west-1-an
```

Download the kernel from S3 on other instances:

```bash
aws s3 cp s3://muhamad-tirocinio-bucket-861507897222-eu-west-1-an/kernel-6.1.161-custom.tar.gz .
sudo tar -xzf kernel-6.1.161-custom.tar.gz -C /

# Register the kernel
sudo grubby --add-kernel=/boot/vmlinuz-6.1.161-custom \
  --initrd=/boot/initramfs-6.1.161-custom.img \
  --title="Linux 6.1.161 custom (GFS2+DLM)" \
  --copy-default \
  --make-default

# Verify
# sudo grubby --default-kernel

sudo reboot
```

Verify: 

```bash
# Confirm new kernel
uname -r

# Load and verify modules
sudo modprobe gfs2
sudo modprobe dlm

lsmod | grep -E "gfs2|dlm"

# Check module info
modinfo gfs2
modinfo dlm
modinfo gfs2 | grep -E "filename|version"
modinfo dlm | grep -E "filename|version"
```

Now mount the EBS volume in multiattach mode.

## Pacemaker Cluster Set Up

On all nodes: 

```bash
sudo dnf install -y pcs pacemaker
sudo systemctl enable --now pcsd.service
sudo systemctl enable pcsd.service
sudo systemctl enable corosync pacemaker
# use same password on all nodes
echo "hacluster:pass" | sudo chpasswd
```

On all nodes edit `/etc/hosts` to resolve the names of all other nodes to the private IPs: 

```bash
sudo tee -a /etc/hosts <<EOF
172.31.32.185    ma-host-1
172.31.46.169   ma-host-2
172.31.43.92    ma-host-3
172.31.44.198   ma-host-4
172.31.45.211  ma-host-5
EOF
```

Check connectivity: 

```bash
ping ma-host-1
ping ma-host-2
ping ma-host-3
ping ma-host-4
ping ma-host-5
```

On one node only: 

```bash
# sudo pcs cluster auth
sudo pcs host auth ma-host-1 ma-host-2 ma-host-3 ma-host-4 ma-host-5 -u hacluster -p pass
sudo pcs cluster setup macluster ma-host-1 ma-host-2 ma-host-3 ma-host-4 ma-host-5
sudo pcs cluster start --all
sudo pcs cluster enable --all
# watch sudo pcs status
```

## Fencing Set Up

On all nodes, install the fencing agent:

```bash
sudo dnf install -y git autoconf automake libtool make gcc python3-devel libcurl-devel openssl-devel
sudo dnf install -y \
  python3-boto3 \
  python3-botocore \
  python3-requests \
  python3-pexpect \
  python3-pycurl \
  python3-certifi \
  python3-urllib3
  
cd /tmp
git clone https://github.com/ClusterLabs/fence-agents.git
cd fence-agents
./autogen.sh
./configure --with-agents=aws
make
sudo make install
cd ..
cd ..

fence_aws --version
```

Enable fencing (on all nodes):

```bash
sudo pcs property set stonith-enabled=true
sudo pcs property set stonith-action=off
sudo pcs property set startup-fencing=true
sudo pcs property set no-quorum-policy=stop
sudo pcs property set stonith-timeout=600s
```

In case of errors: 

```bash
sudo journalctl -u pacemaker --no-pager | grep -i fence | tail -30
sudo tail -50 /var/log/cluster/corosync.log
```

Assign a IAM role with the correct permissions to EC2 istances: 

```yaml
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "ec2:DescribeInstances",
        "ec2:DescribeInstancesStatus",
        "ec2:StartInstances",
        "ec2:StopInstances",
        "ec2:RebootInstances"
      ],
      "Resource": "*"
    }
  ]
}
```

Then set up fence using the IAM role (only on one node):

```bash
sudo pcs stonith create clusterfence fence_aws \
  region=eu-west-1 \
  pcmk_host_map="ma-host-1:i-09fa22a7809259e88;ma-host-2:i-0220f1e6066bc5451;ma-host-3:i-07fc1cd80ebfc6637;ma-host-4:i-08e17c17419f06e68;ma-host-5:i-05e17cc4b2d29000d" \
  power_timeout=240 pcmk_off_timeout=600 pcmk_reboot_timeout=480 pcmk_reboot_retries=4
```

In case of error, launch the agent manually in verbose mode:

```bash
fence_aws -o status -n i-0d6dcd2303280703f --region eu-west-1 --plug i-0d6dcd2303280703f --verbose
AWS_DEFAULT_REGION=eu-west-1 fence_aws -o status -n i-0d6dcd2303280703f --region eu-west-1 --plug i-0d6dcd2303280703f --verbose
sudo env -i HOME=/root PATH=/usr/sbin:/usr/bin fence_aws -o monitor --region eu-west-1 2>&1
```

To reload the fence agent after some changes:

```bash
sudo pcs resource cleanup clusterfence
sudo pcs resource enable clusterfence
sudo pcs status
```

## GFS2 Set Up

On all nodes, download and build GFS, DLM and LVM:

Install development tool:

```bash
sudo dnf groupinstall -y "Development Tools"
sudo dnf install -y \
  git make gcc \
  libaio-devel \
  autoconf automake libtool \
  ncurses-devel gettext \
  bison flex \
  zlib-devel bzip2-devel \
  libblkid-devel libuuid-devel
  
sudo dnf install -y \
  kernel-devel pkgconfig \
  corosynclib-devel \
  libqb-devel \
  systemd-devel \
  libxml2-devel \
  pacemaker-libs-devel \
  readline-devel \
  device-mapper-devel \
  device-mapper-event-devel
```

Build gfs2-utils from source:

```bash
cd /tmp
git clone https://pagure.io/gfs2-utils.git
cd gfs2-utils
./autogen.sh
./configure --prefix=/usr --sbindir=/usr/sbin --sysconfdir=/etc
make -j$(nproc)
sudo make install
cd /
```

Build dlm from source:

```bash
cd /tmp
git clone https://pagure.io/dlm.git
cd dlm
./configure
make -j$(nproc)
sudo make install
sudo ldconfig 
cd /
```

Build lvm2-cluster (from LVM2):

```bash
cd /tmp
git clone https://gitlab.com/lvmteam/lvm2.git
cd lvm2
./configure \
  --enable-lvmlockd-dlm \
  --disable-lvmlockd-sanlock \
  --enable-cluster \
  --enable-cmocks \
  --prefix=/usr \
  --sbindir=/usr/sbin \
  --sysconfdir=/etc \
  --localstatedir=/var
make -j$(nproc)
sudo rm -f /usr/sbin/lvmlockd
sudo rm -f /usr/sbin/lvmlockctl
sudo make install
sudo ldconfig
cd /
```

Create a systemd service for LVM2: 

```bash
sudo tee /etc/systemd/system/lvmlockd.service << 'EOF'
[Unit]
Description=LVM lock daemon
After=network.target

[Service]
Type=simple
ExecStart=/usr/sbin/lvmlockd -f
ExecStop=/usr/sbin/lvmlockd --kill
Restart=no

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo sed -i 's/use_lvmlockd = 0/use_lvmlockd = 1/' /etc/lvm/lvm.conf
```

Then mount and configure the dlm module (on all nodes):

```bash
sudo mount -t configfs none /sys/kernel/config
sudo modprobe dlm
sudo modprobe gfs2

echo "configfs /sys/kernel/config configfs defaults 0 0" | sudo tee -a /etc/fstab
cat <<EOF | sudo tee /etc/modules-load.d/cluster.conf
dlm
gfs2
EOF

# create device node
MINOR=$(cat /proc/misc | grep dlm-control | awk '{print $1}')
sudo mkdir -p /dev/misc
sudo mknod /dev/misc/dlm-control c 10 $MINOR 2>/dev/null || true
sudo chmod 600 /dev/misc/dlm-control

MINOR=$(cat /proc/misc | grep "dlm-monitor" | awk '{print $1}')
sudo mknod /dev/misc/dlm-monitor c 10 $MINOR
sudo chmod 600 /dev/misc/dlm-monitor

# Create persistent udev rule
echo 'KERNEL=="dlm-control", SUBSYSTEM=="misc", MODE="0600"' | \
  sudo tee /etc/udev/rules.d/99-dlm.rules
  
echo 'KERNEL=="dlm-monitor", SUBSYSTEM=="misc", MODE="0600"' | \
  sudo tee -a /etc/udev/rules.d/99-dlm.rules
  
sudo udevadm control --reload-rules
sudo udevadm trigger --subsystem-match=misc
sudo udevadm settle

# lsmod | grep -E "gfs2|lock_dlm|dlm"
```

On all nodes, create the shared folder:

```bash
sudo mkdir /sharedFS
```

Only on one node:

```bash
sudo pcs resource create dlm ocf:pacemaker:controld \
  op monitor interval=30s on-fail=fence \
  clone interleave=true ordered=true

sudo pcs resource create lvmlockd ocf:heartbeat:lvmlockd \
  op monitor interval=30s on-fail=fence \
  clone interleave=true ordered=true

sudo pcs constraint order start dlm-clone then lvmlockd-clone
sudo pcs constraint colocation add lvmlockd-clone with dlm-clone

sleep 15

sudo pvcreate /dev/nvme1n1
sudo vgcreate --shared clustervg /dev/nvme1n1
sudo lvcreate -L20G -n clusterlv clustervg
sudo vgchange --lock-start clustervg
sudo vgchange -asy clustervg
sudo mkfs.gfs2 -j5 -p lock_dlm -t macluster:sharedFS /dev/clustervg/clusterlv
sudo vgchange -an clustervg

sudo pcs resource create clusterfs_lvm ocf:heartbeat:LVM-activate \
  vgname=clustervg \
  vg_access_mode=lvmlockd \
  activation_mode=shared \
  op monitor interval=30s on-fail=fence \
  clone interleave=true ordered=true

sudo pcs constraint order start lvmlockd-clone then clusterfs_lvm-clone
sudo pcs constraint colocation add clusterfs_lvm-clone with lvmlockd-clone

sudo pcs resource create clusterfs ocf:heartbeat:Filesystem \
  device="/dev/clustervg/clusterlv" \
  directory="/sharedFS" \
  fstype="gfs2" \
  options="noatime" \
  op monitor interval=10s on-fail=fence \
  clone interleave=true

sudo pcs constraint order start clusterfs_lvm-clone then clusterfs-clone
sudo pcs constraint colocation add clusterfs-clone with clusterfs_lvm-clone

sudo pcs resource cleanup
sudo pcs status
```

In case of errors, try cleaning up the resources:

```bash
sudo pcs resource cleanup dlm
sudo pcs resource cleanup lvmlockd
sudo pcs resource cleanup clusterfs

# Watch it recover
watch sudo pcs status
```

Or try to force LVM to rescan and activate the VG (on the broken nodes):

```bash
sudo pvscan --cache
sudo vgscan
sudo vgchange -ay clustervg
sudo lvs
```