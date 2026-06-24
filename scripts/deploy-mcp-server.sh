#!/usr/bin/env bash
# Deploy Runbook MCP Server to Amazon Bedrock AgentCore Runtime
# Prerequisites: npm install -g @aws/agentcore (v0.6.0+), jq, AWS CLI
set -euo pipefail

source config.env
REGION="${AWS_REGION:-us-east-1}"
STACK="${ENVIRONMENT_NAME:-dev}-emr-spark-alert-reduction"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
PROJECT_NAME="runbookmcp"
AGENT_NAME="runbook_mcp"

info()  { echo -e "\033[36m[INFO]\033[0m  $*"; }
error() { echo -e "\033[31m[ERROR]\033[0m $*" >&2; }
ok()    { echo -e "\033[32m[OK]\033[0m    $*"; }

if ! command -v agentcore &>/dev/null; then
  error "AgentCore CLI not found. Install: sudo npm install -g @aws/agentcore"
  exit 1
fi

# Get KB and bucket from stack outputs
KB_ID=$(aws bedrock-agent list-knowledge-bases --region "$REGION" \
  --query "knowledgeBaseSummaries[?starts_with(name,'${ENVIRONMENT_NAME}-emr-runbooks-kb') && status=='ACTIVE'].knowledgeBaseId" --output text)
# S3 bucket security: BPA, SSE-S3 (AES-256), HTTPS-only bucket policy, and
# server access logging are all configured in infrastructure/template.yaml
# (DataBucket + DataBucketPolicy + LoggingBucket resources). This script only
# reads the bucket name from CloudFormation outputs — it does not configure
# bucket security settings.
BUCKET=$(aws cloudformation describe-stacks --stack-name "$STACK" --region "$REGION" \
  --query "Stacks[0].Outputs[?OutputKey=='DataBucketName'].OutputValue" --output text)
EMR_LOG_GROUP="${EMR_LOG_GROUP:-/emr-on-eks/${ENVIRONMENT_NAME}}"
info "KB: $KB_ID | Bucket: $BUCKET | Account: $ACCOUNT_ID"

# --- Step 1: Cognito (reuse if exists) ---
POOL_ID=$(aws cognito-idp list-user-pools --max-results 20 --region "$REGION" \
  --query "UserPools[?Name=='emr-spark-mcp-pool'].Id" --output text 2>/dev/null || echo "")

if [ -z "$POOL_ID" ] || [ "$POOL_ID" = "None" ]; then
  info "Creating Cognito user pool ..."
  POOL_ID=$(aws cognito-idp create-user-pool --pool-name "emr-spark-mcp-pool" \
    --policies '{"PasswordPolicy":{"MinimumLength":12,"RequireUppercase":true,"RequireLowercase":true,"RequireNumbers":true,"RequireSymbols":true}}' \
    --region "$REGION" --query "UserPool.Id" --output text)

  # Domain + resource server (required for client_credentials OAuth flow)
  aws cognito-idp create-user-pool-domain \
    --user-pool-id "$POOL_ID" --domain "emr-spark-mcp-${ACCOUNT_ID}" \
    --region "$REGION" > /dev/null 2>&1 || true
  aws cognito-idp create-resource-server \
    --user-pool-id "$POOL_ID" --identifier "mcp-api" --name "MCP API" \
    --scopes '[{"ScopeName":"invoke","ScopeDescription":"Invoke MCP server"}]' \
    --region "$REGION" > /dev/null 2>&1 || true

  # Client with secret + client_credentials (for DevOps Agent OAuth)
  CLIENT_JSON=$(aws cognito-idp create-user-pool-client \
    --user-pool-id "$POOL_ID" --client-name "emr-spark-mcp-client" \
    --generate-secret \
    --explicit-auth-flows ALLOW_USER_PASSWORD_AUTH ALLOW_REFRESH_TOKEN_AUTH \
    --allowed-o-auth-flows client_credentials \
    --allowed-o-auth-flows-user-pool-client \
    --allowed-o-auth-scopes "mcp-api/invoke" \
    --region "$REGION" --query "UserPoolClient" --output json)
  CLIENT_ID=$(echo "$CLIENT_JSON" | jq -r '.ClientId')
  CLIENT_SECRET=$(echo "$CLIENT_JSON" | jq -r '.ClientSecret')

  ok "Cognito pool: $POOL_ID | Client: $CLIENT_ID"
else
  CLIENT_ID=$(aws cognito-idp list-user-pool-clients --user-pool-id "$POOL_ID" \
    --region "$REGION" --query "UserPoolClients[0].ClientId" --output text)
  CLIENT_SECRET=$(aws cognito-idp describe-user-pool-client --user-pool-id "$POOL_ID" \
    --client-id "$CLIENT_ID" --region "$REGION" --query "UserPoolClient.ClientSecret" --output text 2>/dev/null || echo "")
  ok "Cognito pool exists: $POOL_ID | Client: $CLIENT_ID"
fi
DISCOVERY_URL="https://cognito-idp.${REGION}.amazonaws.com/${POOL_ID}/.well-known/openid-configuration"
COGNITO_DOMAIN="https://emr-spark-mcp-${ACCOUNT_ID}.auth.${REGION}.amazoncognito.com"

# --- Step 2: Prepare MCP server code ---
DEPLOY_DIR=$(mktemp -d)
info "Preparing code in $DEPLOY_DIR ..."

mkdir -p "$DEPLOY_DIR/code/tools"
cp mcp_server/models.py "$DEPLOY_DIR/code/models.py"
cp mcp_server/tools/runbook_tools.py "$DEPLOY_DIR/code/tools/runbook_tools.py"
echo "from tools import runbook_tools" > "$DEPLOY_DIR/code/tools/__init__.py"
touch "$DEPLOY_DIR/code/__init__.py"

# Fix imports: repo uses mcp_server.X, Amazon Bedrock AgentCore needs flat imports
sed -i 's/from mcp_server\./from /g' "$DEPLOY_DIR/code/tools/runbook_tools.py"

# Create app.py with hardcoded env defaults (CDK doesn't map environmentVariables)
cat > "$DEPLOY_DIR/code/app.py" << PYEOF
"""Amazon EMR Spark Runbook MCP Server — runbook tools only.
Amazon EMR job status, Spark logs, and Amazon CloudWatch metrics come from DevOps Agent built-in capabilities.
"""
import os

os.environ.setdefault("KNOWLEDGE_BASE_ID", "${KB_ID}")
os.environ.setdefault("RUNBOOK_BUCKET", "${BUCKET}")
os.environ.setdefault("AWS_REGION", "${REGION}")

from typing import Optional
from mcp.server.fastmcp import FastMCP
from models import MCPErrorResponse
from tools import runbook_tools

mcp = FastMCP("emr-spark-runbook-mcp", host="0.0.0.0", stateless_http=True)

@mcp.tool()
async def search_runbooks(query: str, severity_filter: Optional[str] = None, category_filter: Optional[str] = None) -> dict:
    """Semantic search over Amazon EMR and Apache Spark runbooks via Amazon Bedrock Knowledge Base."""
    try:
        result = await runbook_tools.search_runbooks(query=query, severity_filter=severity_filter, category_filter=category_filter)
        return result.model_dump()
    except Exception as exc:
        return MCPErrorResponse(error_code="KB_UNAVAILABLE", message=f"Knowledge Base search failed: {exc}").model_dump()

@mcp.tool()
async def get_runbook(runbook_id: str) -> dict:
    """Retrieve full runbook content from S3 by identifier."""
    try:
        return (await runbook_tools.get_runbook(runbook_id=runbook_id)).model_dump()
    except Exception as exc:
        return MCPErrorResponse(error_code="S3_ERROR", message=f"Failed to retrieve runbook: {exc}").model_dump()

@mcp.tool()
async def list_runbooks() -> list:
    """List all available runbooks with scenario names, severity, and tags."""
    try:
        return [r.model_dump() for r in await runbook_tools.list_runbooks()]
    except Exception as exc:
        return [MCPErrorResponse(error_code="S3_ERROR", message=f"Failed to list runbooks: {exc}").model_dump()]

if __name__ == "__main__":
    mcp.run(transport="streamable-http")
PYEOF

# pyproject.toml required by agentcore
cat > "$DEPLOY_DIR/code/pyproject.toml" << 'EOF'
[project]
name = "emr-spark-runbook-mcp"
version = "1.0.0"
requires-python = ">=3.11"
dependencies = ["mcp>=1.0.0", "pyyaml>=6.0", "pydantic>=2.0", "boto3>=1.28.0"]
EOF

# --- Step 3: Create Amazon Bedrock AgentCore project ---
cd "$DEPLOY_DIR"
info "Creating Amazon Bedrock AgentCore project ..."
agentcore create \
  --name "$PROJECT_NAME" \
  --protocol MCP \
  --no-agent \
  --build CodeZip \
  --skip-git \
  --skip-python-setup 2>&1 | tail -3

cd "$PROJECT_NAME"

# Set aws-targets.json
cat > agentcore/aws-targets.json << EOF
[{"name":"default","region":"${REGION}","account":"${ACCOUNT_ID}"}]
EOF

# Add agent
info "Adding agent ..."
agentcore add agent \
  --name "$AGENT_NAME" \
  --type byo \
  --protocol MCP \
  --language python \
  --code-location "$DEPLOY_DIR/code" \
  --entrypoint app.py \
  --authorizer-type CUSTOM_JWT \
  --discovery-url "$DISCOVERY_URL" \
  --allowed-clients "$CLIENT_ID" 2>&1 | tail -3

# Add env vars to agentcore.json (CDK doesn't map them, but we hardcoded defaults in app.py)
python3 -c "
import json
with open('agentcore/agentcore.json') as f:
    c = json.load(f)
c['runtimes'][0]['environmentVariables'] = {
    'KNOWLEDGE_BASE_ID': '${KB_ID}',
    'RUNBOOK_BUCKET': '${BUCKET}',
    'AWS_REGION': '${REGION}'
}
with open('agentcore/agentcore.json', 'w') as f:
    json.dump(c, f, indent=2)
"

# --- Step 4: Deploy ---
info "Deploying to Amazon Bedrock AgentCore Runtime (2-3 min) ..."
DEPLOY_OUTPUT=$(agentcore deploy -y --target default 2>&1)
echo "$DEPLOY_OUTPUT" | tail -10

# --- Step 5: Get runtime info ---
# Try state.json first, fall back to parsing deploy output
STATE_FILE="agentcore/.cli/state.json"
if [ -f "$STATE_FILE" ]; then
  RUNTIME_ID=$(python3 -c "
import json
with open('$STATE_FILE') as f:
    s = json.load(f)
rt = s['targets']['default']['resources']['runtimes']['${AGENT_NAME}']
print(rt['runtimeId'])
")
  ROLE_ARN=$(python3 -c "
import json
with open('$STATE_FILE') as f:
    s = json.load(f)
print(s['targets']['default']['resources']['runtimes']['${AGENT_NAME}']['roleArn'])
")
else
  info "state.json not found, parsing deploy output ..."
  RUNTIME_ID=$(echo "$DEPLOY_OUTPUT" | grep -o 'runtime/[^ ]*' | head -1 | sed 's|runtime/||')
  ROLE_ARN=$(echo "$DEPLOY_OUTPUT" | grep 'RoleArn' | grep -o 'arn:aws:iam::[^ ]*' | head -1)
fi

if [ -z "$RUNTIME_ID" ] || [ -z "$ROLE_ARN" ]; then
  err "Could not determine Runtime ID or Role ARN from deploy output."
  err "Check the deploy output above and set manually:"
  err "  RUNTIME_ID=<from RuntimeIdOutput>"
  err "  ROLE_ARN=<from RoleArnOutput>"
  exit 1
fi

RUNTIME_ARN="arn:aws:bedrock-agentcore:${REGION}:${ACCOUNT_ID}:runtime/${RUNTIME_ID}"
ROLE_NAME=$(echo "$ROLE_ARN" | sed 's|.*/||')

# --- Step 6: Add IAM policies to the Amazon Bedrock AgentCore-created role ---
#
# See docs/SECURITY_CONSIDERATIONS.md for shared responsibility, AI/ML security
# controls, and input validation details.
#
# Note: cloudwatch:GetMetricData does not support resource-level permissions
# (AWS service limitation). Resource: "*" is required; compensating control
# is the cloudwatch:namespace condition restricting to AWS/EMRContainers.
info "Adding IAM policies to runtime role: $ROLE_NAME ..."
aws iam put-role-policy --role-name "$ROLE_NAME" \
  --policy-name "RunbookMCPAccess" \
  --policy-document '{
    "Version": "2012-10-17",
    "Statement": [
      {
        "Sid": "BedrockKnowledgeBaseAccess",
        "Effect": "Allow",
        "Action": ["bedrock:Retrieve", "bedrock:InvokeModel", "bedrock:RetrieveAndGenerate",
                    "bedrock-agent:Retrieve", "bedrock-agent:RetrieveAndGenerate"],
        "Resource": [
          "arn:aws:bedrock:'"$REGION"':'"$ACCOUNT_ID"':knowledge-base/*",
          "arn:aws:bedrock:'"$REGION"'::foundation-model/amazon.titan-embed-text-v1",
          "arn:aws:bedrock:'"$REGION"'::foundation-model/anthropic.claude-*"
        ],
        "Condition": {
          "StringEquals": {"aws:PrincipalAccount": "'"$ACCOUNT_ID"'"}
        }
      },
      {
        "Effect": "Allow",
        "Action": ["s3:GetObject", "s3:ListBucket"],
        "Resource": ["arn:aws:s3:::'"$BUCKET"'", "arn:aws:s3:::'"$BUCKET"'/*"]
      },
      {
        "Sid": "EMRContainersAccess",
        "Effect": "Allow",
        "Action": ["emr-containers:DescribeJobRun", "emr-containers:ListJobRuns"],
        "Resource": "arn:aws:emr-containers:'"$REGION"':'"$ACCOUNT_ID"':/virtualclusters/*"
      },
      {
        "Sid": "CloudWatchLogsAccess",
        "Effect": "Allow",
        "Action": ["logs:FilterLogEvents", "logs:GetLogEvents", "logs:DescribeLogGroups", "logs:DescribeLogStreams"],
        "Resource": [
          "arn:aws:logs:'"$REGION"':'"$ACCOUNT_ID"':log-group:'"$EMR_LOG_GROUP"':*",
          "arn:aws:logs:'"$REGION"':'"$ACCOUNT_ID"':log-group:'"$EMR_LOG_GROUP"'"
        ]
      },
      {
        "Sid": "CloudWatchMetricsAccess",
        "Effect": "Allow",
        "Action": ["cloudwatch:GetMetricData"],
        "Resource": "*",
        "Condition": {
          "StringEquals": {"cloudwatch:namespace": "AWS/EMRContainers"}
        }
      }
    ]
  }'
ok "IAM policies added."

# Save deploy dir for future updates
PERSIST_DIR="/tmp/runbook-mcp-deploy"
rm -rf "$PERSIST_DIR"
mkdir -p "$PERSIST_DIR"
cp -r "$DEPLOY_DIR/$PROJECT_NAME" "$PERSIST_DIR/$PROJECT_NAME"
ok "Deploy state saved to $PERSIST_DIR/$PROJECT_NAME"

echo ""
echo "============================================="
echo "  Runbook MCP Deployed to Amazon Bedrock AgentCore"
echo "============================================="
echo "  Runtime ARN   : $RUNTIME_ARN"
echo "  Runtime Role  : $ROLE_NAME"
echo "  Cognito Pool  : $POOL_ID"
echo "  Client ID     : $CLIENT_ID"
echo "  Client Secret : $CLIENT_SECRET"
echo "  Cognito Domain: $COGNITO_DOMAIN"
echo "============================================="
echo ""
echo "  DevOps Agent MCP Registration:"
ESCAPED_ARN=$(python3 -c "import urllib.parse; print(urllib.parse.quote('$RUNTIME_ARN', safe=''))")
echo "    Endpoint URL    : https://bedrock-agentcore.$REGION.amazonaws.com/runtimes/${ESCAPED_ARN}/invocations?qualifier=DEFAULT"
echo "    Auth            : OAuth Client Credentials"
echo "    Client ID       : $CLIENT_ID"
echo "    Client Secret   : $CLIENT_SECRET"
echo "    Exchange URL    : ${COGNITO_DOMAIN}/oauth2/token"
echo "    Exchange Params : grant_type=client_credentials"
echo "    Scope           : mcp-api/invoke"
echo "    Tools           : search_runbooks, get_runbook, list_runbooks"
echo "============================================="
