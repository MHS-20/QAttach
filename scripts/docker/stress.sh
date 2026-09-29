#!/usr/bin/env bash
# stress.sh [ops] [files] — every node runs a random mix of append, unlink,
# read and readdir on a shared directory at full speed.  Prints per-node
# I/O error counts and the agent's contended-wait outcomes.  Expects the
# cluster from run.sh with GFS2 mounted on every node at /mnt/gfs2.
set -uo pipefail
WORK=${QATTACH_DOCKER_WORK:-$HOME/.cache/qattach-docker}
NODES=${NODES:-3}
OPS=${1:-200}
FILES=${2:-20}
here=$(dirname "$0")

"$here/node.sh" 0 'mkdir -p /mnt/gfs2/s' 60 >/dev/null
for ((i = 0; i < NODES; i++)); do : >"$WORK/ctl/node$i/agent.mark"; wc -l <"$WORK/ctl/node$i/agent.log" >"$WORK/ctl/node$i/agent.mark"; done
start=$SECONDS
for ((i = 0; i < NODES; i++)); do
  "$here/node.sh" "$i" "e=0; for k in \$(seq $OPS); do f=/mnt/gfs2/s/f\$((RANDOM % $FILES))
    case \$((RANDOM % 4)) in
      0) echo \$HOSTNAME >>\$f 2>/dev/null || e=\$((e + 1)) ;;
      1) rm -f \$f 2>/dev/null || e=\$((e + 1)) ;;
      2) cat \$f >/dev/null 2>&1 ;;
      3) ls /mnt/gfs2/s >/dev/null 2>&1 || e=\$((e + 1)) ;;
    esac; done; echo \"\$HOSTNAME errors=\$e/$OPS\"" 900 &
done
wait
echo "elapsed $((SECONDS - start))s"
for ((i = 0; i < NODES; i++)); do
  tail -n +"$(($(cat "$WORK/ctl/node$i/agent.mark") + 1))" "$WORK/ctl/node$i/agent.log" |
    awk -v n="node$i" '/acquired/{a++} /reason=1/{c++} /reason=5/{d++} END{printf "%s waits-acquired=%d timeouts=%d deadlocks=%d\n", n, a, c, d}'
done
