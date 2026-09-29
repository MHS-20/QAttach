#!/usr/bin/env bash
# node.sh N 'command' [timeout-seconds] — run a shell command in guest N and
# print its output.  Exits with the command's status, or 124 on timeout
# (the command keeps running in the guest, e.g. a process stuck in D-state).
set -euo pipefail
WORK=${QATTACH_DOCKER_WORK:-$HOME/.cache/qattach-docker}
dir=$WORK/ctl/node$1
name=$(date +%s%N)
printf '%s\n' "$2" >"$dir/.$name"
mv "$dir/.$name" "$dir/cmd-$name.sh"
deadline=$((SECONDS + ${3:-60}))
until [[ -f $dir/$name.rc ]]; do
  ((SECONDS < deadline)) || { cat "$dir/$name.out" 2>/dev/null; exit 124; }
  sleep 0.1
done
cat "$dir/$name.out"
exit "$(cat "$dir/$name.rc")"
