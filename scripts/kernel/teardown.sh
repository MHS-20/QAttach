#!/bin/bash
# teardown.sh — terminate kernel builder instances.
#
# Env: AWS_DEFAULT_REGION (default: eu-west-1)

set -euo pipefail

REGION="${AWS_DEFAULT_REGION:-eu-west-1}"
INSTANCE_NAME="kernel-builder"

echo "=== Finding kernel builder instances to terminate ==="
INSTANCE_IDS=$(aws ec2 describe-instances \
  --region "$REGION" \
  --filters "Name=tag:Name,Values=${INSTANCE_NAME}" "Name=instance-state-name,Values=running,pending,stopped" \
  --query 'Reservations[].Instances[].InstanceId' \
  --output text)

if [[ -n "$INSTANCE_IDS" ]]; then
  echo "Terminating: $INSTANCE_IDS"
  for id in $INSTANCE_IDS; do
    aws ec2 terminate-instances --region "$REGION" --instance-ids "$id" 2>/dev/null || true
  done
  echo "Waiting for termination..."
  for id in $INSTANCE_IDS; do
    aws ec2 wait instance-terminated --region "$REGION" --instance-ids "$id" 2>/dev/null || true
  done
  echo "All kernel builder instances terminated."
else
  echo "No running kernel builder instances found."
fi
