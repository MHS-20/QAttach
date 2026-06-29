#!/bin/bash
# create-infra.sh — provision full QAttach infrastructure.
#
# Creates:
#   1. EC2 key pair (if not existing)
#   2. Security group (etcd + GFS2 ports)
#   3. etcd cluster nodes (t3.medium × 3)
#   4. etcd internal NLB
#   5. EBS io2 Multi-Attach volume
#   6. Compute nodes (t3.medium × N)
#   7. Attaches EBS volume to all compute nodes
#
# Usage:
#   QATTACH_KEY_NAME=mykey QATTACH_PEM_PATH=~/.ssh/id_ed25519 ./create-infra.sh
#
# State is saved to $QATTACH_STATE (default: ../../infra-state.json).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/state.sh"

log "=== QAttach Infrastructure Provisioning ==="
log "Region:      $REGION"
log "AZ:          $AZ"
log "Cluster:     $CLUSTER_NAME"
log "State file:  $QATTACH_STATE"
log ""

# ---- Step 1: Key Pair ----

if [[ -z "$KEY_NAME" ]]; then
    KEY_NAME="${CLUSTER_NAME}-key"
fi

if aws ec2 describe-key-pairs --key-names "$KEY_NAME" &>/dev/null; then
    log "Key pair '$KEY_NAME' already exists"
else
    log "Creating key pair: $KEY_NAME"
    aws ec2 create-key-pair \
        --key-name "$KEY_NAME" \
        --query 'KeyMaterial' --output text > "${PEM_PATH/#\~/$HOME}"
    chmod 400 "${PEM_PATH/#\~/$HOME}"
    log "Saved to ${PEM_PATH}"
fi

state_put key_name "\"$KEY_NAME\""
state_put region "\"$REGION\""
state_put az "\"$AZ\""
state_put cluster_name "\"$CLUSTER_NAME\""

# ---- Step 2: Security Group ----

VPC_ID=$(discover_vpc)
SUBNET_ID=$(discover_subnet)

log "VPC:     $VPC_ID"
log "Subnet:  $SUBNET_ID"

SG_NAME="${CLUSTER_NAME}-sg"
SG_ID=$(aws ec2 describe-security-groups \
    --filters "Name=group-name,Values=$SG_NAME" "Name=vpc-id,Values=$VPC_ID" \
    --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null || echo "")

if [[ -n "$SG_ID" && "$SG_ID" != "None" ]]; then
    log "Security group already exists: $SG_ID"
else
    log "Creating security group: $SG_NAME"
    SG_ID=$(aws ec2 create-security-group \
        --group-name "$SG_NAME" \
        --description "QAttach cluster $CLUSTER_NAME" \
        --vpc-id "$VPC_ID" \
        --tag-specifications "ResourceType=security-group,Tags=[{Key=ClusterName,Value=$CLUSTER_NAME}]" \
        --query 'GroupId' --output text)

    # SSH from anywhere (tighten in production)
    aws ec2 authorize-security-group-ingress \
        --group-id "$SG_ID" --protocol tcp --port 22 --cidr 0.0.0.0/0

    # etcd client port (2379) — internal only
    aws ec2 authorize-security-group-ingress \
        --group-id "$SG_ID" --protocol tcp --port 2379 --source-group "$SG_ID"

    # etcd peer port (2380) — internal only
    aws ec2 authorize-security-group-ingress \
        --group-id "$SG_ID" --protocol tcp --port 2380 --source-group "$SG_ID"

    log "Security group created: $SG_ID"
fi

state_put vpc_id "\"$VPC_ID\""
state_put subnet_id "\"$SUBNET_ID\""
state_put sg_id "\"$SG_ID\""

# ---- Step 3: AMI ----

AMI_ID=$(discover_ami)
log "AMI: $AMI_ID"
state_put ami_id "\"$AMI_ID\""

# ---- Step 4: etcd cluster nodes ----

log ""
log "=== Creating etcd nodes ($ETCD_NODES nodes) ==="

ETCD_IDS=()
ETCD_IPS=()

for i in $(seq 1 $ETCD_NODES); do
    NAME="${CLUSTER_NAME}-etcd-${i}"
    log "Launching $NAME..."

    INST_ID=$(aws ec2 run-instances \
        --image-id "$AMI_ID" \
        --instance-type "$ETCD_INSTANCE_TYPE" \
        --key-name "$KEY_NAME" \
        --security-group-ids "$SG_ID" \
        --subnet-id "$SUBNET_ID" \
        --associate-public-ip-address \
        --block-device-mappings '[{"DeviceName":"/dev/xvda","Ebs":{"VolumeSize":10,"VolumeType":"gp3"}}]' \
        --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$NAME},{Key=ClusterName,Value=$CLUSTER_NAME}]" \
        --query 'Instances[0].InstanceId' --output text)

    ETCD_IDS+=("$INST_ID")
    log "  Instance: $INST_ID"
done

log "Waiting for etcd nodes..."
for id in "${ETCD_IDS[@]}"; do
    wait_for_instance "$id"
    ip=$(get_instance_private_ip "$id")
    ETCD_IPS+=("$ip")
    log "  $id → $ip"
done

state_save_array etcd_instance_ids "${ETCD_IDS[@]}"
state_save_array etcd_ips "${ETCD_IPS[@]}"

# ---- Step 5: etcd endpoint (direct IPs, no NLB) ----

log ""
log "=== Building etcd endpoint list ==="

# Concatenate IPs as comma-separated https://host:2379 endpoints
ETCD_ENDPOINTS=""
for ip in "${ETCD_IPS[@]}"; do
    [[ -n "$ETCD_ENDPOINTS" ]] && ETCD_ENDPOINTS+=","
    ETCD_ENDPOINTS+="https://${ip}:2379"
done

log "Endpoints: $ETCD_ENDPOINTS"
state_put etcd_nlb_dns "\"$ETCD_ENDPOINTS\""

# ---- Step 6: EBS Multi-Attach volume ----

log ""
log "=== Creating EBS volume ==="

VOL_ID=$(aws ec2 create-volume \
    --volume-type io2 \
    --size "$VOLUME_SIZE_GB" \
    --iops "$VOLUME_IOPS" \
    --multi-attach-enabled \
    --availability-zone "$AZ" \
    --tag-specifications "ResourceType=volume,Tags=[{Key=ClusterName,Value=$CLUSTER_NAME},{Key=Name,Value=${CLUSTER_NAME}-gfs2}]" \
    --query 'VolumeId' --output text)

log "Volume: $VOL_ID"
state_put volume_id "\"$VOL_ID\""

# ---- Step 7: Compute nodes ----

log ""
log "=== Creating compute nodes ($COMPUTE_NODES nodes) ==="

COMPUTE_IDS=()
COMPUTE_IPS=()

COMPUTE_SG_ID=$(aws ec2 describe-security-groups \
    --filters "Name=group-name,Values=$SG_NAME" \
    --query 'SecurityGroups[0].GroupId' --output text)

# Add GFS2 / cluster-agent ports
aws ec2 authorize-security-group-ingress \
    --group-id "$COMPUTE_SG_ID" --protocol tcp --port 0-65535 \
    --source-group "$COMPUTE_SG_ID" 2>/dev/null || true

for i in $(seq 1 $COMPUTE_NODES); do
    NAME="${CLUSTER_NAME}-compute-${i}"
    log "Launching $NAME..."

    INST_ID=$(aws ec2 run-instances \
        --image-id "$AMI_ID" \
        --instance-type "$INSTANCE_TYPE" \
        --key-name "$KEY_NAME" \
        --security-group-ids "$COMPUTE_SG_ID" \
        --subnet-id "$SUBNET_ID" \
        --associate-public-ip-address \
        --block-device-mappings '[{"DeviceName":"/dev/xvda","Ebs":{"VolumeSize":10,"VolumeType":"gp3"}}]' \
        --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$NAME},{Key=ClusterName,Value=$CLUSTER_NAME}]" \
        --query 'Instances[0].InstanceId' --output text)

    COMPUTE_IDS+=("$INST_ID")
    log "  Instance: $INST_ID"
done

log "Waiting for compute nodes..."
for id in "${COMPUTE_IDS[@]}"; do
    wait_for_instance "$id"
    ip=$(get_instance_private_ip "$id")
    COMPUTE_IPS+=("$ip")
    log "  $id → $ip"
done

state_save_array compute_instance_ids "${COMPUTE_IDS[@]}"
state_save_array compute_ips "${COMPUTE_IPS[@]}"

# ---- Step 8: Attach EBS to compute nodes ----

log ""
log "=== Attaching EBS to compute nodes ==="

for id in "${COMPUTE_IDS[@]}"; do
    log "Attaching $VOL_ID to $id..."
    aws ec2 attach-volume \
        --volume-id "$VOL_ID" \
        --instance-id "$id" \
        --device /dev/sdf
done

log "Waiting for attachments..."
for id in "${COMPUTE_IDS[@]}"; do
    aws ec2 wait volume-in-use --volume-ids "$VOL_ID" 2>/dev/null || true
done

# ---- Done ----

state_put created_at "\"$(date -Iseconds)\""

log ""
log "============================================"
log "Infrastructure provisioned successfully!"
log "============================================"
log ""
log "State file: $QATTACH_STATE"
log ""
log "Next steps:"
log "  1. Setup etcd:    ./scripts/infra/setup-etcd.sh"
log "  2. Setup compute:  ./scripts/infra/setup-compute.sh"
log "  3. Run tests:     ./scripts/infra/run-full-test.sh"
log ""
log "To SSH:"
log "  ssh -i ${PEM_PATH} ec2-user@<ip>"
log ""
log "To teardown:"
log "  ./scripts/infra/destroy-infra.sh"
