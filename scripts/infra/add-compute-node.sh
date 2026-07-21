#!/bin/bash
# add-compute-node.sh — add a compute node to a running 3-node cluster.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/state.sh"

log "=== Adding node ==="
EXISTING_IP=$(state_get compute_public_ips | jq -r '.[0]')
CERT_DIR="${PROJECT_ROOT}/certs"
[[ -f "$CERT_DIR/ca.key" ]] || die "CA key not found at $CERT_DIR/ca.key"
CLUSTER=$(state_get cluster_name)

# 1. Launch instance
NEW_NODE=$(($(state_get compute_ips | jq 'length') + 1))
AMI=$(state_get ami_id); SG=$(state_get sg_id); SUBNET=$(state_get subnet_id); KEY=$(state_get key_name)
INSTANCE_ID=$(aws ec2 run-instances --image-id "$AMI" --instance-type "$INSTANCE_TYPE" --key-name "$KEY" \
    --security-group-ids "$SG" --subnet-id "$SUBNET" \
    --block-device-mappings '[{"DeviceName":"/dev/xvda","Ebs":{"VolumeSize":30,"VolumeType":"gp3"}}]' \
    --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=ebs-ma-compute-${NEW_NODE}}]" \
    --region "$REGION" --query 'Instances[0].InstanceId' --output text)
aws ec2 wait instance-running --instance-ids "$INSTANCE_ID" --region "$REGION"
PRIV_IP=$(get_instance_private_ip "$INSTANCE_ID"); PUB_IP=$(get_instance_public_ip "$INSTANCE_ID")
log "  $INSTANCE_ID → $PUB_IP / $PRIV_IP"

# 2. Attach volume
VOL=$(state_get volume_id)
aws ec2 attach-volume --volume-id "$VOL" --instance-id "$INSTANCE_ID" --device /dev/sdf --region "$REGION" 2>/dev/null
sleep 5

# Update state
state_append compute_ips "\"$PRIV_IP\""; state_append compute_public_ips "\"$PUB_IP\""; state_append compute_instance_ids "\"$INSTANCE_ID\""

# 3. Deploy kernel
wait_for_ssh "$PUB_IP"
LOCAL_TARBALL="${KERNEL_TARBALL:-$PROJECT_ROOT/kernel-6.18.35-custom.tar.gz}"
log "Deploying kernel..."
$SCRIPT_DIR/deploy-kernel.sh --local-tarball "$LOCAL_TARBALL" "$PUB_IP" 2>&1 | grep -E 'is up:|ERROR' || true
wait_for_ssh "$PUB_IP" 60 5

# 4. Generate certs
ETCD_NAME="etcd-$((NEW_NODE - 1))"; PEER_URL="https://${PRIV_IP}:2380"
log "Generating TLS certs for $ETCD_NAME ($PRIV_IP)..."
cp "$CERT_DIR/ca.crt" /tmp/ca.crt; cp "$CERT_DIR/ca.key" /tmp/ca.key
for t in server peer; do
    openssl req -new -newkey rsa:2048 -nodes -subj "/CN=${ETCD_NAME}" \
        -keyout /tmp/${t}.key -out /tmp/${t}.csr \
        -addext "subjectAltName=IP:${PRIV_IP},IP:127.0.0.1"
    openssl x509 -req -days 3650 -in /tmp/${t}.csr -CA /tmp/ca.crt -CAkey /tmp/ca.key \
        -CAcreateserial -out /tmp/${t}.crt \
        -extfile <(echo "subjectAltName=IP:${PRIV_IP},IP:127.0.0.1")
done; rm -f /tmp/server.csr /tmp/peer.csr

# 5. etcd member add
ENDPOINTS=$(state_get compute_ips | jq -r '.[]' | while read ip; do echo -n "https://${ip}:2379,"; done | sed 's/,$//')
INITIAL_CLUSTER=$(ssh $SSH_OPTS "ec2-user@$EXISTING_IP" "
    sudo ETCDCTL_API=3 etcdctl --endpoints=https://localhost:2379 \
        --cacert=/etc/cluster-agent/ca.crt --cert=/etc/cluster-agent/client.crt \
        --key=/etc/cluster-agent/client.key member list 2>/dev/null
" 2>/dev/null | sed 's/: peerURLs=/=/' | sed 's/,clientURLs.*//' | tr '\n' ',' | sed 's/,$//')
INITIAL_CLUSTER="${INITIAL_CLUSTER},${ETCD_NAME}=${PEER_URL}"
log "Adding etcd member..."
ssh $SSH_OPTS "ec2-user@$EXISTING_IP" "sudo ETCDCTL_API=3 etcdctl --endpoints=https://localhost:2379 \
    --cacert=/etc/cluster-agent/ca.crt --cert=/etc/cluster-agent/client.crt \
    --key=/etc/cluster-agent/client.key member add $ETCD_NAME --peer-urls=$PEER_URL 2>&1 | head -3" 2>/dev/null

# 6. Upload files
log "Uploading certs and binary..."
scp $SSH_OPTS /tmp/ca.crt $CERT_DIR/client.crt $CERT_DIR/client.key "ec2-user@$PUB_IP:/tmp/"
scp $SSH_OPTS /tmp/server.crt /tmp/server.key /tmp/peer.crt /tmp/peer.key "ec2-user@$PUB_IP:/tmp/"
gzip -c "$PROJECT_ROOT/bin/cluster-agent" > /tmp/ca.gz; scp $SSH_OPTS /tmp/ca.gz "ec2-user@$PUB_IP:/tmp/"
rm -f /tmp/ca.crt /tmp/ca.key /tmp/server.* /tmp/peer.* /tmp/ca.gz

# 7. Setup node (install certs, etcd config, agent, systemd)
VOL_ID=$(state_get volume_id); AZ=$(state_get az)
ssh $SSH_OPTS "ec2-user@$PUB_IP" bash <<'SETUP'
set -e
# Cert dirs
sudo mkdir -p /etc/cluster-agent /etc/etcd/tls
sudo cp /tmp/ca.crt /tmp/client.crt /tmp/client.key /etc/cluster-agent/
sudo mv /tmp/server.crt /etc/etcd/tls/server-ETCD.crt
sudo mv /tmp/server.key /etc/etcd/tls/server-ETCD.key
sudo mv /tmp/peer.crt /etc/etcd/tls/peer-ETCD.crt
sudo mv /tmp/peer.key /etc/etcd/tls/peer-ETCD.key
sudo chown -R root:root /etc/cluster-agent /etc/etcd/tls
sudo chmod 600 /etc/cluster-agent/*.key /etc/etcd/tls/*.key 2>/dev/null || true
# Agent binary
gzip -d -f /tmp/ca.gz; sudo mv /tmp/ca /usr/local/bin/cluster-agent; sudo chmod 755 /usr/local/bin/cluster-agent
# etcd args
sudo mkdir -p /etc/etcd /etc/systemd/system/etcd.service.d
cat > /tmp/etcd.args <<'ARGS'
--name ETCD
--data-dir /var/lib/etcd
--listen-client-urls https://0.0.0.0:2379
--advertise-client-urls https://IP:2379
--listen-peer-urls https://0.0.0.0:2380
--initial-advertise-peer-urls PEER
--initial-cluster CLUSTER
--initial-cluster-state existing
--initial-cluster-token TOK
--client-cert-auth
--trusted-ca-file /etc/cluster-agent/ca.crt
--cert-file /etc/etcd/tls/server-ETCD.crt
--key-file /etc/etcd/tls/server-ETCD.key
--peer-client-cert-auth
--peer-trusted-ca-file /etc/cluster-agent/ca.crt
--peer-cert-file /etc/etcd/tls/peer-ETCD.crt
--peer-key-file /etc/etcd/tls/peer-ETCD.key
ARGS
sudo mv /tmp/etcd.args /etc/etcd/etcd.args
# Dropin
sudo tee /etc/systemd/system/etcd.service.d/qattach.conf > /dev/null <<'DROPIN'
[Service]
ExecStart=
ExecStart=/bin/sh -c 'exec /usr/local/bin/etcd $(cat /etc/etcd/etcd.args)'
Restart=always
DROPIN
SETUP

# Replace placeholders in etcd args
ssh $SSH_OPTS "ec2-user@$PUB_IP" "
sudo sed -i 's/ETCD/${ETCD_NAME}/g' /etc/etcd/etcd.args
sudo sed -i 's|IP|${PRIV_IP}|g' /etc/etcd/etcd.args
sudo sed -i 's|PEER|${PEER_URL}|g' /etc/etcd/etcd.args
sudo sed -i 's|CLUSTER|${INITIAL_CLUSTER}|g' /etc/etcd/etcd.args
sudo sed -i 's|TOK|${CLUSTER}|g' /etc/etcd/etcd.args
" 2>/dev/null

# 8. Agent systemd unit + start
ssh $SSH_OPTS "ec2-user@$PUB_IP" "
sudo tee /etc/systemd/system/cluster-agent.service > /dev/null <<EOF
[Unit]
Description=GFS2 Cluster Agent (etcd-backed, colocated)
After=network-online.target etcd.service
Wants=network-online.target etcd.service
[Service]
Type=simple
ExecStartPre=/sbin/modprobe gfs2
ExecStart=/usr/local/bin/cluster-agent \\
  --etcd-endpoints=${ENDPOINTS} \\
  --etcd-name=${ETCD_NAME} \\
  --peer-url=${PEER_URL} \\
  --initial-cluster=${INITIAL_CLUSTER} \\
  --volume-id=${VOL_ID} \\
  --cluster-name=${CLUSTER} \\
  --az=${AZ} \\
  --etcd-cert=/etc/cluster-agent/client.crt \\
  --etcd-key=/etc/cluster-agent/client.key \\
  --etcd-ca=/etc/cluster-agent/ca.crt
Restart=always
RestartSec=5
[Install]
WantedBy=multi-user.target
EOF
sudo systemctl daemon-reload
sudo systemctl enable etcd cluster-agent
sudo systemctl start etcd cluster-agent
" 2>/dev/null

# 9. Wait + mount
log "Waiting for agent..."
wait_for_agent_ready "$PUB_IP" 90 2 || { log "ERROR: agent not ready"; exit 1; }
log "Mounting GFS2..."
ssh $SSH_OPTS "ec2-user@$PUB_IP" "
sudo modprobe gfs2 2>/dev/null; sudo mkdir -p /mnt/shared
sudo mount -t gfs2 -o lockproto=lock_etcd,locktable=${CLUSTER}:sharedfs /dev/nvme1n1 /mnt/shared 2>&1
mountpoint /mnt/shared && echo MOUNTED || { echo FAILED; exit 1; }
" 2>/dev/null

log "=== Node added: $PUB_IP ($ETCD_NAME) ==="
