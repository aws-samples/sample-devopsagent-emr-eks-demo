#!/usr/bin/env bash
# Print all values needed for DevOps Agent console setup
set -euo pipefail

source config.env 2>/dev/null || { echo "config.env not found"; exit 1; }
REGION="${AWS_REGION:-us-east-1}"
ENV="${ENVIRONMENT_NAME:-dev}"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

echo ""
echo "============================================="
echo "  DevOps Agent Console Setup Values"
echo "============================================="
echo ""

# ── Agent Space ───────────────────────────────────────────────────────────
echo "── 1. Agent Space ──"
echo "  Name       : emr-spark-alert-reduction"
echo "  Tag filter : devopsagent = true"
echo ""

# ── EKS Access ────────────────────────────────────────────────────────────
echo "── 2. EKS Access ──"
echo "  Cluster    : ${EKS_CLUSTER_NAME}"
echo "  Region     : ${REGION}"
echo ""

# ── Private Connection (SHS MCP) ─────────────────────────────────────────
echo "── 3. Private Connection ──"
VPC_ID=$(aws eks describe-cluster --name "$EKS_CLUSTER_NAME" --region "$REGION" \
  --query 'cluster.resourcesVpcConfig.vpcId' --output text 2>/dev/null || echo "UNKNOWN")
SUBNETS=$(aws eks describe-cluster --name "$EKS_CLUSTER_NAME" --region "$REGION" \
  --query 'cluster.resourcesVpcConfig.subnetIds' --output json 2>/dev/null | jq -r '.[]' | tr '\n' ',' | sed 's/,$//')
SG_ID=$(aws ec2 describe-security-groups --region "$REGION" \
  --filters "Name=group-name,Values=${ENV}-shs-mcp-private-connection-sg" "Name=vpc-id,Values=$VPC_ID" \
  --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null || echo "UNKNOWN")
NLB_HOST=$(kubectl get svc shs-mcp-mcp-apache-spark-history-server -n spark-history \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "UNKNOWN")
CERT=$(kubectl get secret shs-mcp-tls -n spark-history -o jsonpath='{.data.tls\.crt}' 2>/dev/null | base64 -d)

echo "  Name       : shs-mcp-private"
echo "  VPC        : $VPC_ID"
echo "  Subnets    : $SUBNETS"
echo "  Security Group : $SG_ID"
echo "  Host       : $NLB_HOST"
echo "  Port range : 18889"
echo ""
echo "  Certificate (paste into console):"
echo "$CERT"
echo ""

# ── SHS MCP Server ────────────────────────────────────────────────────────
API_KEY=$(kubectl get secret shs-mcp-apikey -n spark-history -o jsonpath='{.data.api-key}' 2>/dev/null | base64 -d 2>/dev/null || echo "")
if [ -z "$API_KEY" ]; then
  echo "Warning: shs-mcp-apikey Kubernetes Secret not found. Run deploy.sh first."
fi
echo "── 4. Register SHS MCP Server ──"
echo "  Name       : spark-history-mcp"
echo "  Endpoint   : https://${NLB_HOST}:18889/mcp/"
echo "  Private Connection : shs-mcp-private"
echo "  Auth       : API Key"
echo "    Header   : x-api-key"
echo "    Value    : (retrieved from Kubernetes Secret — not printed)"
echo ""

# ── Runbook MCP Server ────────────────────────────────────────────────────
echo "── 5. Register Runbook MCP Server ──"
RUNTIME_ARN=$(aws cloudformation describe-stacks --stack-name AgentCore-runbookmcp-default --region "$REGION" \
  --query "Stacks[0].Outputs[?contains(OutputKey,'RuntimeArn')].OutputValue" --output text 2>/dev/null || echo "")
POOL_ID=$(aws cognito-idp list-user-pools --max-results 20 --region "$REGION" \
  --query "UserPools[?Name=='emr-spark-mcp-pool'].Id" --output text 2>/dev/null || echo "")
CLIENT_ID=$(aws cognito-idp list-user-pool-clients --user-pool-id "$POOL_ID" --region "$REGION" \
  --query "UserPoolClients[?ClientName=='emr-spark-mcp-client'].ClientId" --output text 2>/dev/null || echo "")
CLIENT_SECRET=$(aws cognito-idp describe-user-pool-client --user-pool-id "$POOL_ID" --client-id "$CLIENT_ID" --region "$REGION" \
  --query "UserPoolClient.ClientSecret" --output text 2>/dev/null || echo "")
COGNITO_DOMAIN="https://emr-spark-mcp-${ACCOUNT_ID}.auth.${REGION}.amazoncognito.com/oauth2/token"

# Build the full AgentCore invocation endpoint URL from the runtime ARN
if [ -n "$RUNTIME_ARN" ] && [ "$RUNTIME_ARN" != "None" ]; then
  ESCAPED_ARN=$(python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1], safe=''))" "$RUNTIME_ARN")
  MCP_ENDPOINT="https://bedrock-agentcore.${REGION}.amazonaws.com/runtimes/${ESCAPED_ARN}/invocations?qualifier=DEFAULT"
else
  MCP_ENDPOINT="UNKNOWN (AgentCore stack not found — run deploy-mcp-server.sh)"
fi

echo "  Name       : runbook-mcp"
echo "  Endpoint   : $MCP_ENDPOINT"
echo "  Auth       : OAuth Client Credentials"
echo "    Client ID     : $CLIENT_ID"
echo "    Client Secret : $CLIENT_SECRET"
echo "    Token URL     : $COGNITO_DOMAIN"
echo "    Scope         : mcp-api/invoke"
echo ""

echo "============================================="
echo "  Use these values in the DevOps Agent console"
echo "  See docs/AGENT_SPACE_SETUP_PRIVATE.md"
echo "============================================="
