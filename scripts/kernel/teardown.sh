#!/bin/bash
set -euo pipefail

REGION="eu-west-1"
INSTANCE_NAME="kernel-builder"

echo "=== Finding kernel builder instances to terminate ==="
INSTANCE_IDS=$(aws ec2 describe-instances \
  --region "$REGION" \
  --filters "Name=tag:Name,Values=${INSTANCE_NAME}" "Name=instance-state-name,Values=running,pending,stopped" \
  --query 'Reservations[].Instances[].InstanceId' \
  --output text)

if [[ -n "$INSTANCE_IDS" ]]; then
  echo "Terminating: $INSTANCE_IDS"
  aws ec2 terminate-instances --region "$REGION" --instance-ids $INSTANCE_IDS
  echo "Waiting for termination..."
  aws ec2 wait instance-terminated --region "$REGION" --instance-ids $INSTANCE_IDS
  echo "All kernel builder instances terminated."
else
  echo "No running kernel builder instances found."
fi
