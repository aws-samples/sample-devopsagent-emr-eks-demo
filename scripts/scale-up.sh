#!/usr/bin/env bash
# =============================================================================
# Scale Up Amazon EKS nodes and restore operational state
# =============================================================================
# After scaling ASG to 0, new nodes get different instance IDs.
#
# Required IAM permissions: autoscaling, eks:DescribeCluster, ec2:DescribeInstances,
# elbv2 (Describe*, Register/DeregisterTargets), aoss (Get/UpdateSecurityPolicy).
# See docs/SECURITY_CONSIDERATIONS.md for shared responsibility.
# This script:
#   1. Scales ASG back up
#   2. Waits for nodes to be Ready
#   3. Re-registers nodes in the ALB target group (SHS MCP)
#   4. Verifies AOSS network policy (AllowFromPublic)
#   5. Waits for ALB health checks to pass
#
# Usage: bash scripts/scale-up.sh
# =============================================================================
set -euo pipefail

source config.env
REGION="${AWS_REGION:-us-east-1}"
ENV="${ENVIRONMENT_NAME:-dev}"
DESIRED=${1:-3}

info()  { echo -e "\033[36m[INFO]\033[0m  $*"; }
ok()    { echo -e "\033[32m[OK]\033[0m    $*"; }
err()   { echo -e "\033[31m[ERR]\033[0m  $*" >&2; }

# ── Find ASG ──────────────────────────────────────────────────────────────
info "Finding ASG for EKS cluster $EKS_CLUSTER_NAME ..."
ASG_NAME=$(aws autoscaling describe-auto-scaling-groups --region "$REGION" \
  --query "AutoScalingGroups[?Tags[?Key=='eks:cluster-name' && Value=='${EKS_CLUSTER_NAME}']].AutoScalingGroupName" \
  --output text | head -1)

# Fallback: try name-match (legacy) if tag lookup returns nothing
if [ -z "$ASG_NAME" ] || [ "$ASG_NAME" = "None" ]; then
  ASG_NAME=$(aws autoscaling describe-auto-scaling-groups --region "$REGION" \
    --query "AutoScalingGroups[?contains(AutoScalingGroupName,'${EKS_CLUSTER_NAME}')].AutoScalingGroupName" \
    --output text | head -1)
fi

if [ -z "$ASG_NAME" ] || [ "$ASG_NAME" = "None" ]; then
  err "No ASG found for cluster $EKS_CLUSTER_NAME"
  err "Check tags: aws autoscaling describe-auto-scaling-groups --region $REGION --query \"AutoScalingGroups[].[AutoScalingGroupName,Tags[?Key=='eks:cluster-name'].Value|[0]]\" --output table"
  exit 1
fi
info "Found ASG: $ASG_NAME"

CURRENT=$(aws autoscaling describe-auto-scaling-groups --region "$REGION" \
  --auto-scaling-group-names "$ASG_NAME" \
  --query "AutoScalingGroups[0].DesiredCapacity" --output text)

if [ "$CURRENT" -ge "$DESIRED" ]; then
  info "ASG already at $CURRENT nodes (requested $DESIRED)"
else
  info "Scaling ASG $ASG_NAME from $CURRENT to $DESIRED ..."
  aws autoscaling set-desired-capacity \
    --auto-scaling-group-name "$ASG_NAME" \
    --desired-capacity "$DESIRED" --region "$REGION"
fi

# ── Wait for nodes ────────────────────────────────────────────────────────
info "Waiting for $DESIRED nodes to be Ready ..."
aws eks update-kubeconfig --name "$EKS_CLUSTER_NAME" --region "$REGION" 2>/dev/null

for i in $(seq 1 20); do
  READY=$(kubectl get nodes --no-headers 2>/dev/null | grep -c " Ready" || echo 0)
  if [ "$READY" -ge "$DESIRED" ]; then
    ok "$READY nodes Ready"
    break
  fi
  info "  $READY/$DESIRED Ready (attempt $i/20, waiting 30s ...)"
  sleep 30
done

READY=$(kubectl get nodes --no-headers 2>/dev/null | grep -c " Ready" || echo 0)
if [ "$READY" -lt "$DESIRED" ]; then
  err "Only $READY/$DESIRED nodes Ready after 10 minutes"
  exit 1
fi

# ── Wait for pods ─────────────────────────────────────────────────────────
info "Waiting for SHS and SHS MCP pods ..."
kubectl rollout status deployment/spark-history-server -n spark-history --timeout=120s 2>/dev/null || true
kubectl rollout status deployment/shs-mcp -n spark-history --timeout=180s 2>/dev/null || true
ok "Pods running"

# ── Re-register ALB targets ──────────────────────────────────────────────
info "Re-registering EKS nodes in ALB target group ..."
TG_ARN=$(aws elbv2 describe-target-groups --region "$REGION" \
  --query "TargetGroups[?TargetGroupName=='shs-mcp-tg'].TargetGroupArn" --output text 2>/dev/null)

if [ -z "$TG_ARN" ] || [ "$TG_ARN" = "None" ]; then
  info "No ALB target group found (shs-mcp-tg) — skipping"
else
  # Get the NodePort used by the ALB (from the LoadBalancer service)
  NODE_PORT=$(kubectl get svc spark-history-mcp -n spark-history \
    -o jsonpath='{.spec.ports[0].nodePort}' 2>/dev/null || echo "")
  if [ -z "$NODE_PORT" ]; then
    # Fallback: read from target group config
    NODE_PORT=$(aws elbv2 describe-target-groups --target-group-arns "$TG_ARN" --region "$REGION" \
      --query "TargetGroups[0].Port" --output text)
  fi

  # Deregister any stale targets
  STALE_TARGETS=$(aws elbv2 describe-target-health --target-group-arn "$TG_ARN" --region "$REGION" \
    --query "TargetHealthDescriptions[].Target" --output json 2>/dev/null)
  if [ "$STALE_TARGETS" != "[]" ] && [ "$STALE_TARGETS" != "null" ]; then
    echo "$STALE_TARGETS" | python3 -c "
import json,sys
targets = json.load(sys.stdin)
for t in targets:
    print(f'{t[\"Id\"]}:{t[\"Port\"]}')
" | while read target; do
      ID=$(echo "$target" | cut -d: -f1)
      PORT=$(echo "$target" | cut -d: -f2)
      aws elbv2 deregister-targets --target-group-arn "$TG_ARN" \
        --targets "Id=$ID,Port=$PORT" --region "$REGION" 2>/dev/null || true
    done
    info "Deregistered stale targets"
  fi

  # Register current nodes
  NODE_IDS=$(aws ec2 describe-instances --region "$REGION" \
    --filters "Name=tag:eks:cluster-name,Values=$EKS_CLUSTER_NAME" "Name=instance-state-name,Values=running" \
    --query 'Reservations[*].Instances[*].InstanceId' --output text)

  for ID in $NODE_IDS; do
    aws elbv2 register-targets --target-group-arn "$TG_ARN" \
      --targets "Id=$ID,Port=$NODE_PORT" --region "$REGION" 2>/dev/null || true
    info "  Registered $ID:$NODE_PORT"
  done

  # Wait for at least one healthy target
  info "Waiting for ALB health checks (up to 3 min) ..."
  for i in $(seq 1 18); do
    HEALTHY=$(aws elbv2 describe-target-health --target-group-arn "$TG_ARN" --region "$REGION" \
      --query "length(TargetHealthDescriptions[?TargetHealth.State=='healthy'])" --output text 2>/dev/null)
    if [ "$HEALTHY" -gt 0 ]; then
      ok "$HEALTHY healthy targets"
      break
    fi
    sleep 10
  done
fi

# ── Verify AOSS network policy ───────────────────────────────────────────
info "Checking AOSS network policy ..."
AOSS_POLICY_NAME="${ENV}-emr-kb-net"
ALLOW_PUBLIC=$(aws opensearchserverless get-security-policy \
  --name "$AOSS_POLICY_NAME" --type network --region "$REGION" \
  --query "securityPolicyDetail.policy" --output json 2>/dev/null | \
  python3 -c "
import json,sys
try:
    data = json.load(sys.stdin)
    if isinstance(data, str):
        data = json.loads(data)
    if isinstance(data, list):
        print(str(data[0].get('AllowFromPublic', False)))
    else:
        print('Unknown')
except:
    print('Unknown')
" 2>/dev/null || echo "Unknown")

if [ "$ALLOW_PUBLIC" = "True" ] || [ "$ALLOW_PUBLIC" = "true" ]; then
  ok "AOSS AllowFromPublic = true"
else
  info "AOSS AllowFromPublic is $ALLOW_PUBLIC — fixing ..."
  POLICY_VERSION=$(aws opensearchserverless get-security-policy \
    --name "$AOSS_POLICY_NAME" --type network --region "$REGION" \
    --query "securityPolicyDetail.policyVersion" --output text)
  COLLECTION_NAME="${ENV}-emr-kb"
  aws opensearchserverless update-security-policy \
    --name "$AOSS_POLICY_NAME" --type network \
    --policy-version "$POLICY_VERSION" \
    --policy '[{"Rules":[{"ResourceType":"collection","Resource":["collection/'"$COLLECTION_NAME"'"]},{"ResourceType":"dashboard","Resource":["collection/'"$COLLECTION_NAME"'"]}],"AllowFromPublic":true}]' \
    --region "$REGION" > /dev/null
  ok "AOSS network policy fixed"
fi

# ── Summary ───────────────────────────────────────────────────────────────
echo ""
echo "============================================="
echo "  Scale Up Complete"
echo "============================================="
echo "  Nodes    : $DESIRED"
echo "  ASG      : $ASG_NAME"
kubectl get pods -n spark-history --no-headers 2>/dev/null | awk '{printf "  Pod      : %-40s %s\n", $1, $3}'
echo "============================================="
