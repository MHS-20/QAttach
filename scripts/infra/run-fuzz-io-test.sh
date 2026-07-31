#!/bin/bash
# run-fuzz-io-test.sh — multi-node fuzzy I/O stress test.
#
# All nodes concurrently create, write (random size/content), read,
# rename and delete files from a shared pool.  Unlike
# run-randomized-test.sh (fixed file pool, fixed content), this also
# exercises directory-glock churn (create/unlink/rename) which is the
# failure mode documented in docs/retrospective.md and
# docs/debug/deadlock_issuelog.md.  Verifies write/read integrity via
# sha256, not just success/failure of the syscall.
#
# Usage: ./run-fuzz-io-test.sh [duration_sec] [file_count] [ops_per_sec]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/state.sh"

DURATION="${1:-60}"
FILE_COUNT="${2:-12}"
OPS_PER_SEC="${3:-4}"

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

OP_TIMEOUT=10

$SSH_CMD "ec2-user@${COMPUTE_IPS[0]}" "
sudo mkdir -p /mnt/shared/fuzz
sudo rm -rf /mnt/shared/fuzz/*
"

# Worker: create/write/read/rename/unlink on a shared file pool with
# randomized size (0-64KiB) and content, verifying write == read via
# sha256.  Corruption (hash mismatch on a file this node just wrote and
# nobody else touched) is reported distinctly from a hang or an errno,
# since it's the failure class a lost GRANT/DENY or a stale cache would
# produce silently.
WORKER='
#!/bin/bash
set -uo pipefail
DURATION=$1; FILE_COUNT=$2; OPS_PER_SEC=$3; NODE_ID=$4; OP_TIMEOUT=$5
DIR=/mnt/shared/fuzz

DEADLINE=$(( SECONDS + DURATION ))
OK=0; HUNG=0; ERR=0; CORRUPT=0

echo "START $NODE_ID $(hostname) pid=$$ duration=${DURATION}s files=${FILE_COUNT} rate=${OPS_PER_SEC}/s"

while [[ $SECONDS -lt $DEADLINE ]]; do
    fnum=$(( (RANDOM % FILE_COUNT) + 1 ))
    fname="$DIR/f${fnum}"
    op=$(( RANDOM % 6 ))

    case $op in
    0)
        # Fuzzy write: random size 1B-64KiB, random content, verify
        # readback hash immediately (EX lock covers both).
        size=$(( (RANDOM % 65536) + 1 ))
        want=$(head -c "$size" /dev/urandom | tee "${fname}.tmp.$$" | sha256sum | awk "{print \$1}")
        timeout $OP_TIMEOUT bash -c "mv \"${fname}.tmp.$$\" \"$fname\"" 2>/dev/null
        rc=$?
        if [[ $rc -eq 124 ]]; then HUNG=$((HUNG+1)); echo "HUNG $NODE_ID op=write-fuzz file=$fname" >&2
        elif [[ $rc -ne 0 ]]; then ERR=$((ERR+1)); rm -f "${fname}.tmp.$$"
        else
            got=$(timeout $OP_TIMEOUT sha256sum "$fname" 2>/dev/null | awk "{print \$1}")
            if [[ "$got" == "$want" ]]; then OK=$((OK+1))
            else CORRUPT=$((CORRUPT+1)); echo "CORRUPT $NODE_ID file=$fname want=$want got=$got" >&2
            fi
        fi
        ;;
    1)
        # Append random-size chunk.
        size=$(( (RANDOM % 4096) + 1 ))
        timeout $OP_TIMEOUT bash -c "head -c $size /dev/urandom >> \"$fname\"" 2>/dev/null
        rc=$?
        [[ $rc -eq 124 ]] && { HUNG=$((HUNG+1)); echo "HUNG $NODE_ID op=append file=$fname" >&2; } \
            || { [[ $rc -ne 0 ]] && ERR=$((ERR+1)) || OK=$((OK+1)); }
        ;;
    2)
        # Full read (SH lock).
        timeout $OP_TIMEOUT bash -c "cat \"$fname\" > /dev/null 2>&1 || true"
        rc=$?
        [[ $rc -eq 124 ]] && { HUNG=$((HUNG+1)); echo "HUNG $NODE_ID op=read file=$fname" >&2; } || OK=$((OK+1))
        ;;
    3)
        # stat (SH lock, lighter weight).
        timeout $OP_TIMEOUT bash -c "stat \"$fname\" > /dev/null 2>&1 || true"
        rc=$?
        [[ $rc -eq 124 ]] && { HUNG=$((HUNG+1)); echo "HUNG $NODE_ID op=stat file=$fname" >&2; } || OK=$((OK+1))
        ;;
    4)
        # Create a fresh, uniquely-named file — directory EX contention,
        # the failure mode docs/retrospective.md describes as unfixable.
        newname="$DIR/new-n${NODE_ID}-$$-$(date +%s%N)"
        timeout $OP_TIMEOUT bash -c "head -c 256 /dev/urandom > \"$newname\"" 2>/dev/null
        rc=$?
        if [[ $rc -eq 124 ]]; then HUNG=$((HUNG+1)); echo "HUNG $NODE_ID op=create file=$newname" >&2
        elif [[ $rc -ne 0 ]]; then ERR=$((ERR+1))
        else
            OK=$((OK+1))
            timeout $OP_TIMEOUT rm -f "$newname" 2>/dev/null
            rc2=$?
            [[ $rc2 -eq 124 ]] && { HUNG=$((HUNG+1)); echo "HUNG $NODE_ID op=unlink file=$newname" >&2; } || OK=$((OK+1))
        fi
        ;;
    5)
        # ls the shared dir — directory SH lock, cheap but frequent in
        # practice and exercises cross-node metadata visibility.
        timeout $OP_TIMEOUT bash -c "ls \"$DIR\" > /dev/null 2>&1 || true"
        rc=$?
        [[ $rc -eq 124 ]] && { HUNG=$((HUNG+1)); echo "HUNG $NODE_ID op=ls" >&2; } || OK=$((OK+1))
        ;;
    esac

    sleep "$(awk "BEGIN{printf \"%.3f\", 1.0 / $OPS_PER_SEC}")"
done

echo "DONE $NODE_ID ok=$OK hung=$HUNG err=$ERR corrupt=$CORRUPT"
'

for ((i=0; i<COMPUTE_COUNT; i++)); do
    ip="${COMPUTE_IPS[$i]}"
    log "Deploying fuzz worker to Node $i ($ip)..."
    echo "$WORKER" | $SSH_CMD "ec2-user@${ip}" "cat > /tmp/fuzz_worker.sh; chmod +x /tmp/fuzz_worker.sh"
done

log "Starting ${DURATION}s fuzz test ($COMPUTE_COUNT nodes, $FILE_COUNT files, $OPS_PER_SEC ops/s)..."
log ""

PIDS=()
for ((i=0; i<COMPUTE_COUNT; i++)); do
    ip="${COMPUTE_IPS[$i]}"
    res_file="$RESULT_DIR/fuzz_node${i}.out"
    $SSH_CMD "ec2-user@${ip}" \
        "sudo /tmp/fuzz_worker.sh $DURATION $FILE_COUNT $OPS_PER_SEC $i $OP_TIMEOUT" \
        > "$res_file" 2>&1 &
    PIDS+=($!)
done

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

TOTAL_OK=0; TOTAL_HUNG=0; TOTAL_ERR=0; TOTAL_CORRUPT=0

for ((i=0; i<COMPUTE_COUNT; i++)); do
    res_file="$RESULT_DIR/fuzz_node${i}.out"
    ip="${COMPUTE_IPS[$i]}"

    ok=$(grep "^DONE $i " "$res_file" 2>/dev/null | awk '{print $3}' | sed 's/ok=//')
    hung=$(grep "^DONE $i " "$res_file" 2>/dev/null | awk '{print $4}' | sed 's/hung=//')
    err=$(grep "^DONE $i " "$res_file" 2>/dev/null | awk '{print $5}' | sed 's/err=//')
    corrupt=$(grep "^DONE $i " "$res_file" 2>/dev/null | awk '{print $6}' | sed 's/corrupt=//')

    ok="${ok:-0}"; hung="${hung:-0}"; err="${err:-0}"; corrupt="${corrupt:-0}"
    ops_node=$(( ok + hung + err + corrupt ))
    TOTAL_OK=$(( TOTAL_OK + ok ))
    TOTAL_HUNG=$(( TOTAL_HUNG + hung ))
    TOTAL_ERR=$(( TOTAL_ERR + err ))
    TOTAL_CORRUPT=$(( TOTAL_CORRUPT + corrupt ))

    if [[ "$corrupt" -gt 0 ]]; then
        fail "Node $i ($ip): $ok ok, $hung hung, $err err, $corrupt CORRUPT ($ops_node ops)"
    elif [[ "$hung" -gt 0 ]]; then
        fail "Node $i ($ip): $ok ok, $hung HUNG, $err err ($ops_node ops)"
    elif [[ "$err" -gt 0 ]]; then
        fail "Node $i ($ip): $ok ok, $err error ($ops_node ops)"
    elif [[ "$ops_node" -eq 0 ]]; then
        fail "Node $i ($ip): no operations completed"
    else
        pass "Node $i ($ip): $ok ok ($ops_node ops)"
    fi
done

TOTAL_OPS=$(( TOTAL_OK + TOTAL_HUNG + TOTAL_ERR + TOTAL_CORRUPT ))

log ""
log "============================================"
log "Total: $TOTAL_OK ok, $TOTAL_HUNG hung, $TOTAL_ERR err, $TOTAL_CORRUPT corrupt ($TOTAL_OPS ops)"
log "============================================"

if [[ $FAIL -gt 0 ]]; then
    log "Details in: $RESULT_DIR/fuzz_node*.out"
    log "For hangs, check node D-state:  ssh ec2-user@<ip> 'ps -eo pid,stat,wchan:32,cmd | grep D'"
    log "For corruption, check dmesg for BAST/GRANT/DENY around the reported timestamp"
    exit 1
fi
