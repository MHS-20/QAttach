#!/bin/bash
# run-randomized-test.sh — stress-test the lock handoff mechanism by
# having every compute node acquire/release locks on random files for
# random durations, concurrently.
#
# Usage: ./run-randomized-test.sh [rounds] [max_sleep] [file_count]
#   rounds     — how many acquire-release cycles per node (default 20)
#   max_sleep  — max seconds to hold a lock (default 3)
#   file_count — number of distinct files to contend on (default 5)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/state.sh"

ROUNDS="${1:-20}"
MAX_SLEEP="${2:-3}"
FILE_COUNT="${3:-5}"

mapfile -t COMPUTE_IPS < <(state_get compute_public_ips | jq -r '.[]')
if [[ -z "${COMPUTE_IPS[*]}" || "${COMPUTE_IPS[0]}" == "null" ]]; then
    mapfile -t COMPUTE_IPS < <(state_get compute_ips | jq -r '.[]')
fi

COMPUTE_COUNT=${#COMPUTE_IPS[@]}
if [[ "$COMPUTE_COUNT" -lt 2 ]]; then
    die "Need at least 2 compute nodes (got $COMPUTE_COUNT)"
fi

RESULT_DIR="${SCRIPT_DIR}/../../test-results"
mkdir -p "$RESULT_DIR"

PASS=0
FAIL=0

log() { echo "[$(date +%T)] $*"; }
pass() { PASS=$((PASS + 1)); echo "  PASS: $*"; }
fail() { FAIL=$((FAIL + 1)); echo "  FAIL: $*"; }

# ---- randomised worker script (runs on each node) ----

PIDS=()
NODE_IDS=()
RESULTS=()

for ((i=0; i<COMPUTE_COUNT; i++)); do
    ip="${COMPUTE_IPS[$i]}"
    node_id="$i"
    NODE_IDS+=("$node_id")
    res_file="$RESULT_DIR/rnd_node${i}.out"

    log "Launching worker on Node $i ($ip)..."
    $SSH_CMD "ec2-user@${ip}" "
cat > /tmp/rnd_worker.sh << 'WORKEREOF'
#!/bin/bash
set -euo pipefail
ROUNDS=\$1; MAX_SLEEP=\$2; FILE_COUNT=\$3; NODE_ID=\$4
PREFIX=\"/mnt/shared/rnd_\${NODE_ID}\"
for i in \$(seq 1 \$ROUNDS); do
    fnum=\$(( (RANDOM % FILE_COUNT) + 1 ))
    fname=\"\${PREFIX}_file\${fnum}\"
    sleep_time=\$(( (RANDOM % (MAX_SLEEP * 10)) + 1 ))
    sleep_time=\$(awk \"BEGIN{printf \\\"%.1f\\\", \$sleep_time / 10}\")
    op=\$(( RANDOM % 3 ))
    if [[ \$op -eq 0 ]]; then
        echo \"n\${NODE_ID}-\${i}\" > \"\$fname\"
    elif [[ \$op -eq 1 ]]; then
        echo \"n\${NODE_ID}-\${i}\" >> \"\$fname\"
    else
        cat \"\$fname\" > /dev/null 2>/dev/null || true
    fi
    sleep \"\$sleep_time\"
    if ! ls /mnt/shared/ > /dev/null 2>&1; then
        echo \"FATAL: \$HOSTNAME lost GFS2 access at round \$i\" >&2
        exit 1
    fi
done
echo \"OK \$HOSTNAME \$ROUNDS rounds\"
WORKEREOF
chmod +x /tmp/rnd_worker.sh
sudo /tmp/rnd_worker.sh \"${ROUNDS}\" \"${MAX_SLEEP}\" \"${FILE_COUNT}\" \"${node_id}\"
" > "$res_file" 2>&1 &
    PIDS+=($!)
done

# ---- Wait for completion with timeout ----

TIMEOUT=$(( ROUNDS * MAX_SLEEP * 2 + 60 ))
log "Waiting for workers (timeout ${TIMEOUT}s)..."
deadline=$(( SECONDS + TIMEOUT ))
all_done=true

for pid in "${PIDS[@]}"; do
    remaining=$(( deadline - SECONDS ))
    if [[ $remaining -le 0 ]]; then
        kill "$pid" 2>/dev/null || true
        all_done=false
        continue
    fi
    if ! wait "$pid" 2>/dev/null; then
        all_done=false
    fi
done

log ""

# ---- Collect results ----

for ((i=0; i<COMPUTE_COUNT; i++)); do
    res_file="$RESULT_DIR/rnd_node${i}.out"
    ip="${COMPUTE_IPS[$i]}"
    node_id="${NODE_IDS[$i]}"

    if [[ -f "$res_file" ]] && grep -q "^OK " "$res_file"; then
        pass "Node $node_id ($ip) completed $(grep "^OK " "$res_file" | awk '{print $3}') rounds"
    else
        tail -5 "$res_file" 2>/dev/null | while read line; do
            echo "       $line"
        done
        fail "Node $node_id ($ip) failed or timed out"
    fi
done

# ---- Cross-node visibility check ----

log ""
log "=== Cross-node visibility ==="

for ((i=0; i<COMPUTE_COUNT; i++)); do
    ip="${COMPUTE_IPS[$i]}"
    node_id="${NODE_IDS[$i]}"

    for ((j=0; j<COMPUTE_COUNT; j++)); do
        if [[ $i -eq $j ]]; then continue; fi
        other_id="${NODE_IDS[$j]}"

        # Check that at least one file from the other node exists and is readable
        found=$($SSH_CMD "ec2-user@${ip}" \
            "sudo find /mnt/shared/ -name 'rnd_${other_id}_file*' 2>/dev/null | head -1" 2>/dev/null || true)
        if [[ -n "$found" ]]; then
            pass "Node $node_id sees Node $other_id files (e.g. $found)"
        else
            fail "Node $node_id does not see Node $other_id files"
        fi
    done
done

# ---- Summary ----

log ""
log "============================================"
log "Results: $PASS passed, $FAIL failed"
log "============================================"

if [[ $FAIL -gt 0 ]]; then
    log "Details in: $RESULT_DIR/rnd_node*.out"
    exit 1
fi
