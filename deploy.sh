#!/usr/bin/env bash
# =============================================================================
# Amazon EMR Spark Alert Reduction — One-Click Deployment
# =============================================================================
# Deploys the complete environment:
#   1. Patches Amazon EMR execution role
#   2. Deploys CFN stack + Amazon Bedrock Knowledge Base + runbooks
#   3. Deploys Spark History Server on Amazon EKS
#   4. Deploys Runbook MCP to Amazon Bedrock AgentCore Runtime
#   5. Deploys SHS MCP on Amazon EKS via Helm + internal NLB (Private Connection)
#
# Prerequisites:
#   - Amazon EKS cluster with Amazon EMR on EKS (e.g., data-on-eks emr-eks-karpenter blueprint)
#   - AWS CLI, kubectl, jq, helm, AgentCore CLI (npm install -g @aws/agentcore)
#   - config.env populated from config.env.template
#
# Usage: ./deploy.sh
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

info()  { echo -e "\n\033[36m━━━ $* ━━━\033[0m"; }
ok()    { echo -e "\033[32m✅ $*\033[0m"; }
err()   { echo -e "\033[31m❌ $*\033[0m" >&2; }

# ── Preflight checks ──────────────────────────────────────────────────────
info "Preflight checks"

for cmd in aws kubectl jq helm openssl; do
  command -v "$cmd" &>/dev/null || { err "$cmd not found. Install it first."; exit 1; }
  echo "  ✓ $cmd"
done

if ! command -v agentcore &>/dev/null; then
  err "AgentCore CLI not found. Install: sudo npm install -g @aws/agentcore"
  err "(Required for Runbook MCP deployment to Amazon Bedrock AgentCore Runtime)"
  exit 1
fi
echo "  ✓ agentcore"

if [ ! -f config.env ]; then
  err "config.env not found. Copy config.env.template and fill in values."
  exit 1
fi
echo "  ✓ config.env"

source config.env
for var in AWS_REGION EKS_CLUSTER_NAME; do
  if [ -z "${!var:-}" ]; then err "$var not set in config.env"; exit 1; fi
done
REGION="${AWS_REGION:-us-east-1}"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
echo "  ✓ AWS account: $ACCOUNT_ID | Region: $REGION"

aws eks update-kubeconfig --name "$EKS_CLUSTER_NAME" --region "$REGION" 2>/dev/null
echo "  ✓ kubectl configured for $EKS_CLUSTER_NAME"

# ── Step 1: Patch Amazon EMR role ─────────────────────────────────────────
# Adds two scoped inline policies to the EMR execution role:
#   - CloudWatchLogsAccess: logs:CreateLogGroup/CreateLogStream/PutLogEvents
#     scoped to /emr-on-eks/* and /aws/emr-containers/* log groups
#   - RunbookBucketAccess: s3:GetObject/ListBucket on the full bucket;
#     s3:PutObject/DeleteObject scoped to spark-events/, logs/, output/, jobs/ prefixes
# Verify after patching with: aws iam list-role-policies --role-name <role>
# See scripts/patch-emr-role.sh for the exact policy JSON.
info "Step 1/5: Patching Amazon EMR execution role"
bash scripts/patch-emr-role.sh
ok "Amazon EMR role patched"

# ── Step 2: Deploy CFN + Amazon Bedrock Knowledge Base + runbooks ─────────
info "Step 2/5: Deploying infrastructure (CFN + Amazon Bedrock Knowledge Base + runbooks)"
bash scripts/deploy-infra.sh
ok "Infrastructure deployed"

# ── Step 3: Deploy Spark History Server ───────────────────────────────────
info "Step 3/5: Deploying Spark History Server on Amazon EKS"
if bash scripts/deploy-shs.sh; then
  ok "Spark History Server deployed"
else
  err "SHS deployment timed out (image pull can be slow on first run)."
  err "Check: kubectl get pods -n spark-history"
  err "If ImagePullBackOff, verify the image in spark-history-mcp/shs-deployment-v2.yaml"
  err "Continuing with remaining steps..."
fi

# ── Step 4: Deploy Runbook MCP ────────────────────────────────────────────
info "Step 4/5: Deploying Runbook MCP to Amazon Bedrock AgentCore Runtime"
if bash scripts/deploy-mcp-server.sh; then
  ok "Runbook MCP deployed"
else
  err "Runbook MCP deployment had errors. Check output above."
  err "You can re-run: bash scripts/deploy-mcp-server.sh"
  err "Continuing with remaining steps..."
fi

# ── Step 5: Deploy SHS MCP via Helm + internal NLB ────────────────────────
info "Step 5/5: Deploying SHS MCP on Amazon EKS via Helm (internal NLB)"
bash scripts/deploy-shs-mcp-private.sh
ok "SHS MCP deployed"

# ── Done ──────────────────────────────────────────────────────────────────

# ── Summary ───────────────────────────────────────────────────────────────
info "Deployment Complete!"
cat << 'EOF'

  ┌─────────────────────────────────────────────────────────────────┐
  │                    Next Steps                                   │
  │                                                                 │
  │  1. Set up DevOps Agent Space (see docs/AGENT_SPACE_SETUP.md) │
  │  2. Create Private Connection for SHS MCP (internal NLB)            │
  │  3. Register both MCP servers in the Agent Space                    │
  │  4. Test: cd fault-injection && ./inject-bad-column.sh              │
  │  5. Investigate in DevOps Agent Web App                             │
  │                                                                 │
  └─────────────────────────────────────────────────────────────────┘

EOF
