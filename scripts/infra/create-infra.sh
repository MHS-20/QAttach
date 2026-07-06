#!/bin/bash
# create-infra.sh — provision full QAttach infrastructure.
#
# Creates:
#   1. EC2 key pair (if not existing)
#   2. Security group (etcd + GFS2 ports)
#   3. EBS io2 Multi-Attach volume
#   4. Compute nodes (where etcd is colocated)
#   5. Attaches EBS volume to all compute nodes
#
# Etcd is colocated on compute nodes — no dedicated etcd instances or NLB.
# Compute node count is the etcd member count (min 3 for quorum).
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
log "Nodes:       $COMPUTE_NODES (etcd colocated)"
log "State file:  $QATTACH_STATE"
log ""

# ---- Step 1: Key Pair ----

# NEVER overwrite an existing private key.
# Always use QATTACH_KEY_NAME=muhamad-keypair.
REAL_PEM="${PEM_PATH/#\~/$HOME}"

if [[ -z "$KEY_NAME" ]]; then
    die "QATTACH_KEY_NAME must be set (e.g. QATTACH_KEY_NAME=muhamad-keypair)"
fi

if [[ ! -f "$REAL_PEM" ]]; then
    die "Private key not found at $REAL_PEM. Create one with: ssh-keygen -t ed25519 -f $REAL_PEM"
fi

log "Using existing key: $REAL_PEM (key pair: $KEY_NAME)"

if aws ec2 describe-key-pairs --key-names "$KEY_NAME" &>/dev/null; then
    log "Key pair '$KEY_NAME' already exists in AWS"
else
    log "Importing local public key as AWS key pair '$KEY_NAME'..."
    aws ec2 import-key-pair \
        --key-name "$KEY_NAME" \
        --public-key-material "fileb://${REAL_PEM}.pub"
    log "Imported."
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

    # All traffic within SG (GFS2, etcd, debugging)
    aws ec2 authorize-security-group-ingress \
        --group-id "$SG_ID" --protocol tcp --port 0-65535 --source-group "$SG_ID" 2>/dev/null || true

    log "Security group created: $SG_ID"
fi

state_put vpc_id "\"$VPC_ID\""
state_put subnet_id "\"$SUBNET_ID\""
state_put sg_id "\"$SG_ID\""

# ---- Step 3: AMI ----

AMI_ID=$(discover_ami)
log "AMI: $AMI_ID"
state_put ami_id "\"$AMI_ID\""

# ---- Step 4: EBS Multi-Attach volume ----

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

# ---- Step 5: Compute nodes (etcd colocated) ----

log ""
log "=== Creating compute nodes ($COMPUTE_NODES nodes, etcd colocated) ==="

COMPUTE_IDS=()
COMPUTE_IPS=()
COMPUTE_PUB_IPS=()

for i in $(seq 1 $COMPUTE_NODES); do
    NAME="${CLUSTER_NAME}-compute-${i}"
    log "Launching $NAME..."
    # Larger root disk for etcd WAL + GFS2 builds
    INST_ID=$(aws ec2 run-instances \
        --image-id "$AMI_ID" \
        --instance-type "$INSTANCE_TYPE" \
        --key-name "$KEY_NAME" \
        --security-group-ids "$SG_ID" \
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
    pub=$(get_instance_public_ip "$id")
    COMPUTE_IPS+=("$ip")
    COMPUTE_PUB_IPS+=("$pub")
    log "  $id → $pub / $ip"
done

state_save_array compute_instance_ids "${COMPUTE_IDS[@]}"
state_save_array compute_ips "${COMPUTE_IPS[@]}"
state_save_array compute_public_ips "${COMPUTE_PUB_IPS[@]}"

# ---- Step 6: etcd endpoints (colocated — compute IPs) ----

log ""
log "=== Building etcd endpoint list (colocated) ==="

ETCD_ENDPOINTS=""
for ip in "${COMPUTE_IPS[@]}"; do
    [[ -n "$ETCD_ENDPOINTS" ]] && ETCD_ENDPOINTS+=","
    ETCD_ENDPOINTS+="https://${ip}:2379"
done

log "Etcd endpoints: $ETCD_ENDPOINTS"
state_put etcd_endpoints "\"$ETCD_ENDPOINTS\""

# ---- Step 7: Attach EBS to compute nodes ----

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
log "Compute nodes: $COMPUTE_NODES (etcd colocated)"
log ""
log "Next steps:"
log "  1. Setup nodes:   ./scripts/infra/setup-compute.sh"
log "  2. Run tests:     ./scripts/infra/run-full-test.sh"
log ""
log "To SSH:"
log "  ssh -i ${PEM_PATH} ec2-user@<ip>"
log ""
log "To teardown:"
log "  ./scripts/infra/destroy-infra.sh"
