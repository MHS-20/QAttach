#!/bin/bash
# run-light-test.sh — light concurrent I/O on all compute nodes.
#
# Creates shared files in advance with sudo, then runs random operations
# (read/append/write) every 5 seconds on every node concurrently.
#
# Usage: ./run-light-test.sh [duration_sec] [file_count]
#   duration_sec — total runtime (default 60)
#   file_count   — number of shared files (default 3)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/state.sh"

DURATION="${1:-60}"
FILE_COUNT="${2:-3}"
TEST_DIR="/mnt/shared/light-test"
OP_INTERVAL=5

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
rm -f "$RESULT_DIR"/light_node*.out

PASS=0
FAIL=0

log() { echo "[$(date +%T)] $*"; }
pass() { PASS=$((PASS + 1)); echo "  PASS: $*"; }
fail() { FAIL=$((FAIL + 1)); echo "  FAIL: $*"; }

# ---- create test files in advance (single node, sudo) ----

log "Creating $FILE_COUNT test files on ${COMPUTE_IPS[0]}..."

$SSH_CMD "ec2-user@${COMPUTE_IPS[0]}" "
sudo mkdir -p $TEST_DIR
for i in \$(seq 1 $FILE_COUNT); do
    sudo bash -c \"echo 'init-node0-\$i-\$(date +%s)' > ${TEST_DIR}/file_\${i}\"
done
ls -la $TEST_DIR/
"

# ---- check files visible from all nodes ----

log "Verifying test files visible on all nodes..."
for ip in "${COMPUTE_IPS[@]}"; do
    count=$($SSH_CMD "ec2-user@$ip" "sudo ls $TEST_DIR/file_* 2>/dev/null | wc -l" 2>/dev/null | tr -d '[:space:]')
    if [[ "$count" == "$FILE_COUNT" ]]; then
        log "  $ip: $count/$FILE_COUNT files visible"
    else
        fail "$ip: only $count/$FILE_COUNT files visible"
    fi
done
log ""

# ---- worker script deployed to each node ----

WORKER='
#!/bin/bash
set -euo pipefail
DURATION=$1; FILE_COUNT=$2; INTERVAL=$3; NODE_ID=$4; TEST_DIR=$5

DEADLINE=$(( SECONDS + DURATION ))
OK=0
HUNG=0
ERR=0

echo "START node=$NODE_ID pid=$$ duration=${DURATION}s interval=${INTERVAL}s files=${FILE_COUNT}"

while [[ $SECONDS -lt $DEADLINE ]]; do
    fnum=$(( (RANDOM % FILE_COUNT) + 1 ))
    fname="${TEST_DIR}/file_${fnum}"
    op=$(( RANDOM % 4 ))

    case $op in
    0)
        # Overwrite (EX lock)
        val="n${NODE_ID}-$(date +%s%N)"
        if timeout $INTERVAL bash -c "echo \"$val\" > \"$fname\"" 2>/dev/null; then
            OK=$((OK + 1))
        else
            rc=$?
            if [[ $rc -eq 124 ]]; then HUNG=$((HUNG + 1)); else ERR=$((ERR + 1)); fi
        fi
        ;;
    1)
        # Append (EX lock)
        val="n${NODE_ID}-$(date +%s%N)"
        if timeout $INTERVAL bash -c "echo \"$val\" >> \"$fname\"" 2>/dev/null; then
            OK=$((OK + 1))
        else
            rc=$?
            if [[ $rc -eq 124 ]]; then HUNG=$((HUNG + 1)); else ERR=$((ERR + 1)); fi
        fi
        ;;
    2)
        # Read first line (SH lock)
        if timeout $INTERVAL bash -c "head -1 \"$fname\" 2>/dev/null || true" > /dev/null 2>&1; then
            OK=$((OK + 1))
        else
            rc=$?
            if [[ $rc -eq 124 ]]; then HUNG=$((HUNG + 1)); else ERR=$((ERR + 1)); fi
        fi
        ;;
    3)
        # Read whole file (SH lock)
        if timeout $INTERVAL bash -c "cat \"$fname\" 2>/dev/null || true" > /dev/null 2>&1; then
            OK=$((OK + 1))
        else
            rc=$?
            if [[ $rc -eq 124 ]]; then HUNG=$((HUNG + 1)); else ERR=$((ERR + 1)); fi
        fi
        ;;
    esac

    sleep "$INTERVAL"
done

echo "DONE node=$NODE_ID ok=$OK hung=$HUNG err=$ERR"
'

for ((i=0; i<COMPUTE_COUNT; i++)); do
    ip="${COMPUTE_IPS[$i]}"
    echo "$WORKER" | $SSH_CMD "ec2-user@${ip}" "
cat > /tmp/light_worker.sh
chmod +x /tmp/light_worker.sh
"
done

# ---- launch all workers in parallel ----

log "Starting ${DURATION}s light test (${COMPUTE_COUNT} nodes, ${FILE_COUNT} files, ${OP_INTERVAL}s interval)..."
log ""

PIDS=()
for ((i=0; i<COMPUTE_COUNT; i++)); do
    ip="${COMPUTE_IPS[$i]}"
    res_file="$RESULT_DIR/light_node${i}.out"
    $SSH_CMD "ec2-user@${ip}" \
        "sudo /tmp/light_worker.sh $DURATION $FILE_COUNT $OP_INTERVAL $i $TEST_DIR" \
        > "$res_file" 2>&1 &
    PIDS+=($!)
done

# ---- wait for completion ----

TIMEOUT=$(( DURATION + 30 ))
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
    res_file="$RESULT_DIR/light_node${i}.out"
    ip="${COMPUTE_IPS[$i]}"

    if [[ ! -s "$res_file" ]]; then
        fail "Node $i ($ip): no output"
        continue
    fi

    ok=$(grep "^DONE node=$i " "$res_file" 2>/dev/null | awk '{print $3}' | sed 's/ok=//')
    hung=$(grep "^DONE node=$i " "$res_file" 2>/dev/null | awk '{print $4}' | sed 's/hung=//')
    err=$(grep "^DONE node=$i " "$res_file" 2>/dev/null | awk '{print $5}' | sed 's/err=//')

    ok="${ok:-0}"
    hung="${hung:-0}"
    err="${err:-0}"

    ops_node=$(( ok + hung + err ))
    TOTAL_OK=$(( TOTAL_OK + ok ))
    TOTAL_HUNG=$(( TOTAL_HUNG + hung ))
    TOTAL_ERR=$(( TOTAL_ERR + err ))

    if [[ "$hung" -gt 0 ]]; then
        fail "Node $i ($ip): $ok ok, $hung HUNG, $err err ($ops_node ops)"
    elif [[ "$err" -gt 0 ]]; then
        fail "Node $i ($ip): $ok ok, $err err ($ops_node ops)"
    elif [[ "$ops_node" -eq 0 ]]; then
        fail "Node $i ($ip): no operations completed"
    else
        pass "Node $i ($ip): $ok ok ($ops_node ops)"
    fi
done

TOTAL_OPS=$(( TOTAL_OK + TOTAL_HUNG + TOTAL_ERR ))

log ""
log "============================================"
log "Total: $TOTAL_OK ok, $TOTAL_HUNG hung, $TOTAL_ERR err ($TOTAL_OPS ops)"
log "============================================"

if [[ $FAIL -gt 0 ]]; then
    log "Details in: $RESULT_DIR/light_node*.out"
    exit 1
fi

log "Light test passed — no hangs, no errors."
