#!/usr/bin/env bash
# shellcheck disable=SC2016 # the quoted commands expand inside the guest
# crash.sh [node] — crash-recovery check.  The victim node churns metadata
# in a directory, its VM is killed mid-write, and the survivors must then
# work in that directory — which needs the victim's journal replayed first.
# Finishes by unmounting the survivors and running fsck.gfs2 -n.  Expects
# the cluster from run.sh with GFS2 mounted on every node.
set -uo pipefail
NODES=${NODES:-3}
victim=${1:-1}
here=$(dirname "$0")
node() { "$here/node.sh" "$@"; }

node "$victim" 'mkdir -p /mnt/gfs2/c
  (i=0; while :; do i=$((i + 1)); echo "line $i" >>/mnt/gfs2/c/log
     touch /mnt/gfs2/c/f$((i % 50)); rm -f /mnt/gfs2/c/f$(((i + 25) % 50)); done) >/dev/null 2>&1 &
  sleep 3; tail -1 /mnt/gfs2/c/log >/tmp/ctl/synced; sync -f /mnt/gfs2/c/log; sleep 2
  cat /tmp/ctl/synced' 30
synced=$(cat "${QATTACH_DOCKER_WORK:-$HOME/.cache/qattach-docker}/ctl/node$victim/synced")
"$here/run.sh" crash "$victim"
echo "killed node$victim"

start=$SECONDS
for ((i = 0; i < NODES; i++)); do
  ((i == victim)) && continue
  node "$i" "grep -qx '$synced' /mnt/gfs2/c/log && echo 'synced line survived' || echo 'SYNCED LINE LOST'"'
    echo "$HOSTNAME" >>/mnt/gfs2/c/log &&
    for k in $(seq 50); do touch /mnt/gfs2/c/$HOSTNAME-$k; done && ls /mnt/gfs2/c | wc -l' 180
  echo "node$i rc=$? after $((SECONDS - start))s"
done
docker exec qattach-cluster etcdctl get --prefix cluster/recovery
for ((i = 0; i < NODES; i++)); do
  ((i == victim)) || node "$i" 'umount /mnt/gfs2' 120
done
docker exec qattach-cluster fsck.gfs2 -n /work/shared.img 2>&1 | grep -iE "inconsist|wrong|says|invalid|fsck.gfs2 complete"
