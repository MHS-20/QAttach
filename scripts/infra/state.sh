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

# Defaults (overridable via env)
REGION="${AWS_DEFAULT_REGION:-eu-west-1}"
AZ="${QATTACH_AZ:-eu-west-1a}"
CLUSTER_NAME="${QATTACH_CLUSTER:-ebs-ma}"
KEY_NAME="${QATTACH_KEY_NAME:-muhamad-keypair}"
PEM_PATH="${QATTACH_PEM_PATH:-$HOME/.ssh/id_ed25519}"
COMPUTE_NODES="${QATTACH_COMPUTE_NODES:-3}"
INSTANCE_TYPE="${QATTACH_INSTANCE_TYPE:-m7i.large}"
VOLUME_SIZE_GB="${QATTACH_VOLUME_SIZE:-30}"
VOLUME_IOPS="${QATTACH_VOLUME_IOPS:-100}"
SUBNET_ID="${QATTACH_SUBNET:-subnet-6570782d}"
SECURITY_GROUP_ID="${QATTACH_SG:-sg-c56ee982}"
BUILDER_AMI="${QATTACH_BUILDER_AMI:-ami-05cbf8a8aa4e4b755}"
BUILDER_INSTANCE_TYPE="${QATTACH_BUILDER_INSTANCE:-m8i.4xlarge}"
S3_BUCKET="${QATTACH_S3_BUCKET:-s3://muhamad-tirocinio-bucket-861507897222-eu-west-1-an}"

export AWS_DEFAULT_REGION="$REGION"

# Expand ~ in PEM_PATH
PEM="${PEM_PATH/#\~/$HOME}"
SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=10 -o BatchMode=yes -i $PEM"
SSH_CMD="ssh $SSH_OPTS"

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
    aws ec2 describe-images \
        --owners amazon \
        --filters \
            "Name=name,Values=al2023-ami-2023*" \
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

# wait_for_ssh <ip> [max_retries] [delay_secs]
# Polls SSH until ready. Returns 0 on success, 1 on timeout.
wait_for_ssh() {
    local ip="$1"
    local max_retries="${2:-60}"
    local delay="${3:-5}"
    local i=0
    while [[ $i -lt $max_retries ]]; do
        if ssh $SSH_OPTS "ec2-user@${ip}" "echo ok" &>/dev/null; then
            return 0
        fi
        i=$((i + 1))
        sleep "$delay"
    done
    return 1
}

# wait_for_inactive <ip> <service>
# Waits for a systemd service to be inactive (stopped).
wait_for_inactive() {
    local ip="$1" svc="$2"
    local max_retries="${3:-30}"
    local delay="${4:-2}"
    local i=0
    while [[ $i -lt $max_retries ]]; do
        local state
        state=$(ssh $SSH_OPTS "ec2-user@${ip}" "systemctl is-active $svc 2>/dev/null || true" 2>/dev/null)
        if [[ "$state" != "active" ]]; then
            return 0
        fi
        i=$((i + 1))
        sleep "$delay"
    done
    return 1
}

# wait_for_active <ip> <service>
# Waits for a systemd service to become active.
wait_for_active() {
    local ip="$1" svc="$2"
    local max_retries="${3:-30}"
    local delay="${4:-2}"
    local i=0
    while [[ $i -lt $max_retries ]]; do
        local state
        state=$(ssh $SSH_OPTS "ec2-user@${ip}" "systemctl is-active $svc 2>/dev/null || true" 2>/dev/null)
        if [[ "$state" == "active" ]]; then
            return 0
        fi
        i=$((i + 1))
        sleep "$delay"
    done
    return 1
}

# wait_for_etcd <ip> [max_retries]
# Waits for local etcd endpoint to respond.
wait_for_etcd() {
    local ip="$1"
    local max_retries="${2:-30}"
    local delay=2
    local i=0
    while [[ $i -lt $max_retries ]]; do
        if ssh $SSH_OPTS "ec2-user@${ip}" \
            "sudo ETCDCTL_API=3 etcdctl \
              --endpoints=https://localhost:2379 \
              --cacert=/etc/cluster-agent/ca.crt \
              --cert=/etc/cluster-agent/client.crt \
              --key=/etc/cluster-agent/client.key \
              endpoint health 2>&1" | grep -q "is healthy"; then
            return 0
        fi
        i=$((i + 1))
        sleep "$delay"
    done
    return 1
}

# wait_for_agent_ready <ip> [max_retries] [delay_secs]
# Waits for the cluster-agent to be fully ready:
#   1. systemd unit is active (process running)
#   2. local etcd is healthy (cluster bootstrapped/joined)
#   3. agent has registered with the kernel netlink socket (dmesg check)
wait_for_agent_ready() {
    local ip="$1"
    local max_retries="${2:-60}"
    local delay="${3:-2}"
    local i=0
    while [[ $i -lt $max_retries ]]; do
        local active
        active=$(ssh $SSH_OPTS "ec2-user@${ip}" "systemctl is-active cluster-agent 2>/dev/null || true" 2>/dev/null)
        if [[ "$active" != "active" ]]; then
            i=$((i + 1))
            sleep "$delay"
            continue
        fi

        local etcd_ok
        etcd_ok=$(ssh $SSH_OPTS "ec2-user@${ip}" \
            "sudo ETCDCTL_API=3 etcdctl \
              --endpoints=https://localhost:2379 \
              --cacert=/etc/cluster-agent/ca.crt \
              --cert=/etc/cluster-agent/client.crt \
              --key=/etc/cluster-agent/client.key \
              endpoint health 2>&1 | grep -c 'is healthy' | tr -d '[:space:]'" 2>/dev/null || echo 0)
        if [[ "$etcd_ok" != "1" ]]; then
            i=$((i + 1))
            sleep "$delay"
            continue
        fi

        local reg
        reg=$(ssh $SSH_OPTS "ec2-user@${ip}" "sudo dmesg 2>/dev/null | grep -c 'agent registered' | tr -d '[:space:]'" 2>/dev/null || echo 0)
        if [[ "$reg" -eq 0 ]]; then
            i=$((i + 1))
            sleep "$delay"
            continue
        fi

        return 0
    done
    return 1
}

# init state on source
state_init
