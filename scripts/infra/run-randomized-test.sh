#!/bin/bash
# run-randomized-test.sh — multi-node lock stress test.
#
# All nodes randomly read (SH) and write (EX) from a shared pool of
# files concurrently.  Measures throughput, success rate, and detects
# hangs via a per-operation timeout.
#
# Usage: ./run-randomized-test.sh [duration_sec] [file_count] [ops_per_sec]
#   duration_sec — total runtime (default 30)
#   file_count   — number of shared files to contend on (default 8)
#   ops_per_sec  — target operations per node per second (default 5)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/state.sh"

DURATION="${1:-30}"
FILE_COUNT="${2:-8}"
OPS_PER_SEC="${3:-5}"

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
TOTAL_OPS=0

log() { echo "[$(date +%T)] $*"; }
pass() { PASS=$((PASS + 1)); echo "  PASS: $*"; }
fail() { FAIL=$((FAIL + 1)); echo "  FAIL: $*"; }

# Timeout for a single operation (seconds).  If a read or write takes
# longer than this, the test declares a hang.
OP_TIMEOUT=10

# ---- deploy worker script to all nodes ----

# Create shared directory + clean old files (from a single node to avoid contention)
$SSH_CMD "ec2-user@${COMPUTE_IPS[0]}" "
sudo mkdir -p /mnt/shared/stress
sudo rm -f /mnt/shared/stress/shared_file*
"

WORKER='
#!/bin/bash
set -euo pipefail
DURATION=$1; FILE_COUNT=$2; OPS_PER_SEC=$3; NODE_ID=$4; OP_TIMEOUT=$5

# Shared test files — all nodes contend on the same pool
DEADLINE=$(( SECONDS + DURATION ))
OK=0
HUNG=0
ERR=0

echo "START $NODE_ID $(hostname) pid=$$ duration=${DURATION}s files=${FILE_COUNT} rate=${OPS_PER_SEC}/s"

while [[ $SECONDS -lt $DEADLINE ]]; do
    fnum=$(( (RANDOM % FILE_COUNT) + 1 ))
    fname="/mnt/shared/stress/shared_file${fnum}"
    op=$(( RANDOM % 4 ))

    case $op in
    0)
        # Atomic overwrite (EX lock)
        val="n${NODE_ID}-$(date +%s%N)"
        timeout $OP_TIMEOUT bash -c "echo \"$val\" > \"$fname\"" 2>/dev/null
        rc=$?
        ;;
    1)
        # Atomic append (EX lock)
        val="n${NODE_ID}-$(date +%s%N)"
        timeout $OP_TIMEOUT bash -c "echo \"$val\" >> \"$fname\"" 2>/dev/null
        rc=$?
        ;;
    2)
        # Read first line (SH lock)
        timeout $OP_TIMEOUT bash -c "head -1 \"$fname\" 2>/dev/null || true" > /dev/null 2>&1
        rc=$?
        ;;
    3)
        # Read whole file (SH lock)
        timeout $OP_TIMEOUT bash -c "cat \"$fname\" 2>/dev/null || true" > /dev/null 2>&1
        rc=$?
        ;;
    esac

    if [[ $rc -eq 124 ]]; then
        HUNG=$((HUNG + 1))
        echo "HUNG $NODE_ID op=$op file=$fname" >&2
    elif [[ $rc -ne 0 ]]; then
        ERR=$((ERR + 1))
    else
        OK=$((OK + 1))
    fi

    # Pace to target ops/sec
    sleep "$(awk "BEGIN{printf \"%.3f\", 1.0 / $OPS_PER_SEC}")"
done

echo "DONE $NODE_ID ok=$OK hung=$HUNG err=$ERR"
'

for ((i=0; i<COMPUTE_COUNT; i++)); do
    ip="${COMPUTE_IPS[$i]}"
    log "Deploying worker to Node $i ($ip)..."
    echo "$WORKER" | $SSH_CMD "ec2-user@${ip}" "
cat > /tmp/stress_worker.sh
chmod +x /tmp/stress_worker.sh
"
done

# ---- launch all workers in parallel ----

log "Starting $DURATION-second stress test ($COMPUTE_COUNT nodes, $FILE_COUNT files, $OPS_PER_SEC ops/s)..."
log ""

PIDS=()
for ((i=0; i<COMPUTE_COUNT; i++)); do
    ip="${COMPUTE_IPS[$i]}"
    res_file="$RESULT_DIR/stress_node${i}.out"
    $SSH_CMD "ec2-user@${ip}" \
        "sudo /tmp/stress_worker.sh $DURATION $FILE_COUNT $OPS_PER_SEC $i $OP_TIMEOUT" \
        > "$res_file" 2>&1 &
    PIDS+=($!)
done

# ---- wait for completion ----

TIMEOUT=$(( DURATION + 60 ))
log "Waiting up to ${TIMEOUT}s for workers..."
deadline=$(( SECONDS + TIMEOUT ))

for pid in "${PIDS[@]}"; do
    remaining=$(( deadline - SECONDS ))
    if [[ $remaining -le 0 ]]; then
        kill "$pid" 2>/dev/null || true
        fail "Worker timed out"
        continue
    fi
    wait "$pid" 2>/dev/null || true
done

log ""

# ---- collect results ----

TOTAL_OK=0
TOTAL_HUNG=0
TOTAL_ERR=0

for ((i=0; i<COMPUTE_COUNT; i++)); do
    res_file="$RESULT_DIR/stress_node${i}.out"
    ip="${COMPUTE_IPS[$i]}"

    ok=$(grep "^DONE $i " "$res_file" 2>/dev/null | awk '{print $3}' | sed 's/ok=//')
    hung=$(grep "^DONE $i " "$res_file" 2>/dev/null | awk '{print $4}' | sed 's/hung=//')
    err=$(grep "^DONE $i " "$res_file" 2>/dev/null | awk '{print $5}' | sed 's/err=//')

    ok="${ok:-0}"
    hung="${hung:-0}"
    err="${err:-0}"

    ops_node=$(( ok + hung + err ))
    TOTAL_OK=$(( TOTAL_OK + ok ))
    TOTAL_HUNG=$(( TOTAL_HUNG + hung ))
    TOTAL_ERR=$(( TOTAL_ERR + err ))

    if [[ "$hung" -gt 0 ]]; then
        fail "Node $i ($ip): $ok ok, $hung HUNG, $err error ($ops_node ops)"
    elif [[ "$err" -gt 0 ]]; then
        fail "Node $i ($ip): $ok ok, $err error ($ops_node ops)"
    elif [[ "$ops_node" -eq 0 ]]; then
        fail "Node $i ($ip): no operations completed"
    else
        pass "Node $i ($ip): $ok ok ($ops_node ops)"
    fi
done

TOTAL_OPS=$(( TOTAL_OK + TOTAL_HUNG + TOTAL_ERR ))
ELAPSED="$DURATION"

log ""
log "============================================"
log "Throughput: $(( TOTAL_OK * COMPUTE_COUNT / ELAPSED )) ok ops/sec (approx)"
log "Total: $TOTAL_OK ok, $TOTAL_HUNG hung, $TOTAL_ERR err ($TOTAL_OPS ops)"
log "============================================"

if [[ $FAIL -gt 0 ]]; then
    log "Details in: $RESULT_DIR/stress_node*.out"
    exit 1
fi
