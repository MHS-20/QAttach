#!/bin/bash
# destroy-infra.sh — tear down all QAttach infrastructure.
#
# Reads state from $QATTACH_STATE and destroys everything created
# by create-infra.sh.  Use --force to skip confirmation.
# Etcd is colocated on compute nodes — no separate etcd instances or NLB.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/state.sh"

FORCE="${1:-}"

log "=== QAttach Infrastructure Teardown ==="

# ---- read state ----

VOL_ID=$(state_get volume_id)
SG_ID=$(state_get sg_id)
CLUSTER=$(state_get cluster_name)

COMPUTE_IDS=$(state_get compute_instance_ids | jq -r '.[]' 2>/dev/null || echo "")

ALL_IDS="$COMPUTE_IDS"

log "Volume:        $VOL_ID"
log "Security Grp:  $SG_ID"
log "Nodes:         $(echo $ALL_IDS | wc -w)"

if [[ "$FORCE" != "--force" ]]; then
    echo ""
    read -p "Destroy all resources? [y/N] " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        die "aborted"
    fi
fi

# ---- Step 1: Terminate all instances ----

if [[ -n "$ALL_IDS" ]]; then
    log "Terminating instances..."
    for id in $ALL_IDS; do
        [[ -z "$id" || "$id" == "null" ]] && continue
        aws ec2 terminate-instances --instance-ids "$id" 2>/dev/null || true
    done

    log "Waiting for termination..."
    for id in $ALL_IDS; do
        [[ -z "$id" || "$id" == "null" ]] && continue
        aws ec2 wait instance-terminated --instance-ids "$id" 2>/dev/null || true
    done
fi

# ---- Step 2: Delete EBS volume ----

if [[ -n "$VOL_ID" && "$VOL_ID" != "null" ]]; then
    log "Waiting for volume to detach..."
    sleep 10
    aws ec2 delete-volume --volume-id "$VOL_ID" 2>/dev/null || true
    log "Volume $VOL_ID deleted"
fi

# ---- Step 3: Delete security group ----

if [[ -n "$SG_ID" && "$SG_ID" != "null" ]]; then
    sleep 5
    aws ec2 delete-security-group --group-id "$SG_ID" 2>/dev/null || true
    log "Security group $SG_ID deleted"
fi

# ---- Clean up state ----

rm -f "$QATTACH_STATE"

log ""
log "=== Teardown complete ==="
