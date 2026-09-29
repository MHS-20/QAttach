#!/bin/bash
# guest-init.sh — PID 1 inside each QEMU guest (see run.sh).
# Starts the cluster-agent, then executes command files dropped into the
# per-node control share: <ctl>/cmd-<name>.sh -> <name>.out and <name>.rc.
mount -t proc proc /proc
mount -t sysfs sys /sys
mount -t devtmpfs dev /dev
for d in /tmp /run /mnt /var/lib /var/log; do mount -t tmpfs tmpfs "$d"; done
mkdir -p /tmp/ctl /mnt/gfs2
mount -t 9p -o trans=virtio,version=9p2000.L,cache=none ctl /tmp/ctl

node=$(sed -n 's/.*qattach\.node=\([0-9]*\).*/\1/p' /proc/cmdline)
hostname "node$node"
ip link set lo up
ip link set eth0 up
ip addr add 10.0.2.15/24 dev eth0
ip route add default via 10.0.2.2

dmesg -w >/tmp/ctl/dmesg.log 2>&1 &
/work/cluster-agent --no-bootstrap --node-id "node$node" \
  --etcd-endpoints http://10.0.2.2:2379 >/tmp/ctl/agent.log 2>&1 &
until grep -q 'cluster-agent ready' /tmp/ctl/agent.log; do sleep 0.2; done
echo ready >/tmp/ctl/state

while :; do
  for f in /tmp/ctl/cmd-*.sh; do
    [[ -e $f ]] || continue
    name=${f#/tmp/ctl/cmd-}; name=${name%.sh}
    mv "$f" "/tmp/ctl/run-$name.sh"
    ( bash "/tmp/ctl/run-$name.sh" >"/tmp/ctl/$name.out" 2>&1
      echo $? >"/tmp/ctl/$name.rc" ) &
  done
  sleep 0.1
done
