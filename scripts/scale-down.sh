#!/usr/bin/env bash
# =============================================================================
# Scale Down EKS nodes to save costs
# =============================================================================
# Usage: bash scripts/scale-down.sh
# =============================================================================
set -euo pipefail

source config.env
REGION="${AWS_REGION:-us-east-1}"

info()  { echo -e "\033[36m[INFO]\033[0m  $*"; }
ok()    { echo -e "\033[32m[OK]\033[0m    $*"; }

ASG_NAME=$(aws autoscaling describe-auto-scaling-groups --region "$REGION" \
  --query "AutoScalingGroups[?Tags[?Key=='eks:cluster-name' && Value=='${EKS_CLUSTER_NAME}']].AutoScalingGroupName" \
  --output text | head -1)

# Fallback to name-match (legacy)
if [ -z "$ASG_NAME" ] || [ "$ASG_NAME" = "None" ]; then
  ASG_NAME=$(aws autoscaling describe-auto-scaling-groups --region "$REGION" \
    --query "AutoScalingGroups[?contains(AutoScalingGroupName,'${EKS_CLUSTER_NAME}')].AutoScalingGroupName" \
    --output text | head -1)
fi

if [ -z "$ASG_NAME" ] || [ "$ASG_NAME" = "None" ]; then
  echo "[ERR] No ASG found for cluster $EKS_CLUSTER_NAME" >&2
  exit 1
fi

info "Scaling ASG to 0: $ASG_NAME"
aws autoscaling set-desired-capacity \
  --auto-scaling-group-name "$ASG_NAME" \
  --desired-capacity 0 --region "$REGION"

ok "ASG scaled to 0. EKS control plane still running (~\$0.10/hr)."
echo "  To resume: bash scripts/scale-up.sh"
