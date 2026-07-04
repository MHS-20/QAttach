#!/bin/bash
# state.sh — infrastructure state management.
#
# Sources:
#   $QATTACH_STATE   — path to state JSON file (default: infra-state.json)
#   docs/awscli_info.txt — default env values
#
# Provides helpers: state_get, state_put, state_save, state_init

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Default state file
QATTACH_STATE="${QATTACH_STATE:-$PROJECT_ROOT/infra-state.json}"

# Defaults from docs/awscli_info.txt (overridable via env)
REGION="${AWS_DEFAULT_REGION:-eu-west-1}"
AZ="${QATTACH_AZ:-eu-west-1b}"
CLUSTER_NAME="${QATTACH_CLUSTER:-ebs-ma}"
KEY_NAME="${QATTACH_KEY_NAME:-muhamad-keypair}"
PEM_PATH="${QATTACH_PEM_PATH:-~/.ssh/id_ed25519}"
COMPUTE_NODES="${QATTACH_COMPUTE_NODES:-3}"
INSTANCE_TYPE="${QATTACH_INSTANCE_TYPE:-m7i.large}"
VOLUME_SIZE_GB="${QATTACH_VOLUME_SIZE:-30}"
VOLUME_IOPS="${QATTACH_VOLUME_IOPS:-100}"

export AWS_DEFAULT_REGION="$REGION"

log()  { echo "[$(date +%T)] $*"; }
die()  { echo "ERROR: $*" >&2; exit 1; }

# ---- state file helpers ----

state_init() {
    if [[ ! -f "$QATTACH_STATE" ]]; then
        cat > "$QATTACH_STATE" <<'JSON'
{
  "cluster_name": "",
  "region": "",
  "az": "",
  "key_name": "",
  "vpc_id": "",
  "sg_id": "",
  "subnet_id": "",
  "ami_id": "",
  "volume_id": "",
  "compute_ips": [],
  "compute_public_ips": [],
  "compute_instance_ids": [],
  "etcd_endpoints": "",
  "created_at": ""
}
JSON
    fi
}

state_get() {
    local key="$1"
    jq -r ".$key" "$QATTACH_STATE"
}

state_put() {
    local key="$1" value="$2"
    local tmp
    tmp="$(mktemp)"
    jq ".$key = $value" "$QATTACH_STATE" > "$tmp" && mv "$tmp" "$QATTACH_STATE"
}

state_append() {
    local key="$1" value="$2"
    local tmp
    tmp="$(mktemp)"
    jq ".$key += [$value]" "$QATTACH_STATE" > "$tmp" && mv "$tmp" "$QATTACH_STATE"
}

state_save_array() {
    local key="$1"; shift
    local json
    json=$(printf '%s\n' "$@" | jq -R . | jq -s .)
    state_put "$key" "$json"
}

# ---- AWS discovery ----

discover_vpc() {
    aws ec2 describe-vpcs \
        --filters Name=isDefault,Values=true \
        --query 'Vpcs[0].VpcId' --output text
}

discover_subnet() {
    aws ec2 describe-subnets \
        --filters "Name=vpc-id,Values=$(discover_vpc)" "Name=availability-zone,Values=$AZ" \
        --query 'Subnets[0].SubnetId' --output text
}

discover_ami() {
    # Use standard AL2023 with 6.1 kernel (not ECS, not EKS 6.18).
    aws ec2 describe-images \
        --owners amazon \
        --filters \
            "Name=name,Values=al2023-ami-2023*" \
            "Name=name,Values=*kernel-6.1-x86_64*" \
            "Name=architecture,Values=x86_64" \
            "Name=state,Values=available" \
        --query 'sort_by(Images,&CreationDate)[-1].ImageId' --output text
}

# ---- helpers ----

wait_for_instance() {
    local id="$1"
    log "waiting for instance $id to be running..."
    aws ec2 wait instance-running --instance-ids "$id"
}

get_instance_private_ip() {
    local id="$1"
    aws ec2 describe-instances --instance-ids "$id" \
        --query 'Reservations[0].Instances[0].PrivateIpAddress' --output text
}

get_instance_public_ip() {
    local id="$1"
    aws ec2 describe-instances --instance-ids "$id" \
        --query 'Reservations[0].Instances[0].PublicIpAddress' --output text
}

# init state on source
state_init
