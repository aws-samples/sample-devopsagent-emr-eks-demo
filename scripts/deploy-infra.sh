#!/usr/bin/env bash
# Deploy the DevOps Agent layer: S3, AOSS (vector store), Bedrock KB
set -euo pipefail

CONFIG_FILE="config.env"
info()  { echo -e "\033[36m[INFO]\033[0m  $*"; }
error() { echo -e "\033[31m[ERROR]\033[0m $*" >&2; }
ok()    { echo -e "\033[32m[OK]\033[0m    $*"; }
warn()  { echo -e "\033[33m[WARN]\033[0m  $*"; }

if [ ! -f "$CONFIG_FILE" ]; then
  error "$CONFIG_FILE not found. Copy config.env.template and fill in values."
  exit 1
fi
source "$CONFIG_FILE"

for var in AWS_REGION ENVIRONMENT_NAME; do
  if [ -z "${!var:-}" ]; then error "$var not set in $CONFIG_FILE"; exit 1; fi
done

STACK="${ENVIRONMENT_NAME}-emr-spark-alert-reduction"
REGION="${AWS_REGION}"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
info "Stack: $STACK | Region: $REGION | Account: $ACCOUNT_ID"

# --- Step 1: Deploy CloudFormation (S3, KB role, AOSS) ---
info "Deploying CloudFormation ..."
aws cloudformation deploy \
  --template-file infrastructure/template.yaml \
  --stack-name "$STACK" --region "$REGION" \
  --capabilities CAPABILITY_NAMED_IAM \
  --parameter-overrides \
    EnvironmentName="${ENVIRONMENT_NAME}" \
  --no-fail-on-empty-changeset
ok "Stack deployed."

get_output() {
  aws cloudformation describe-stacks \
    --stack-name "$STACK" --region "$REGION" \
    --query "Stacks[0].Outputs[?OutputKey=='$1'].OutputValue" --output text
}

BUCKET=$(get_output "DataBucketName")
KB_ROLE_ARN=$(get_output "KBRoleArn")
AOSS_ARN=$(get_output "AossCollectionArn")

# --- Step 2: Upload runbooks to S3 ---
info "Uploading runbooks to s3://$BUCKET/runbooks/ ..."
aws s3 sync runbooks/ "s3://$BUCKET/runbooks/" --region "$REGION" --delete --sse AES256
ok "Runbooks uploaded."

# --- Step 3: Wait for AOSS collection to be ACTIVE ---
AOSS_ID=$(echo "$AOSS_ARN" | grep -o '[^/]*$')
info "Waiting for AOSS collection $AOSS_ID to become ACTIVE ..."
for i in $(seq 1 30); do
  STATUS=$(aws opensearchserverless batch-get-collection \
    --ids "$AOSS_ID" --region "$REGION" \
    --query "collectionDetails[0].status" --output text 2>/dev/null || echo "UNKNOWN")
  if [ "$STATUS" = "ACTIVE" ]; then ok "AOSS collection is ACTIVE."; break; fi
  info "  Status: $STATUS (${i}/30, waiting 10s ...)"
  sleep 10
done
if [ "$STATUS" != "ACTIVE" ]; then error "AOSS collection did not become ACTIVE in time."; exit 1; fi

AOSS_ENDPOINT=$(aws opensearchserverless batch-get-collection \
  --ids "$AOSS_ID" --region "$REGION" \
  --query "collectionDetails[0].collectionEndpoint" --output text)

# --- Step 4: Create vector index in AOSS (dashboard is public during this step) ---
INDEX_NAME="${ENVIRONMENT_NAME}-emr-runbooks-index"
info "Creating vector index $INDEX_NAME in AOSS ..."
INDEX_RESULT=$(awscurl --service aoss --region "$REGION" \
  -X PUT "${AOSS_ENDPOINT}/${INDEX_NAME}" \
  -H "Content-Type: application/json" \
  -d '{
    "settings": {"index": {"knn": true, "knn.algo_param.ef_search": 512}},
    "mappings": {
      "properties": {
        "embedding": {
          "type": "knn_vector", "dimension": 1536,
          "method": {"engine": "faiss", "name": "hnsw", "parameters": {"m": 16, "ef_construction": 512}, "space_type": "l2"}
        },
        "text": {"type": "text"},
        "metadata": {"type": "text"}
      }
    }
  }' 2>&1 || true)
if echo "$INDEX_RESULT" | grep -q "acknowledged"; then
  ok "Vector index created."
  info "Waiting for index to be available ..."
  sleep 15
elif echo "$INDEX_RESULT" | grep -q "already_exists"; then
  ok "Vector index already exists."
else
  info "Index creation response: $INDEX_RESULT"
fi

# --- Step 4b: Lock down the network policy — remove dashboard public access ---
# Now that the index exists, no public access is needed. Both collection and
# dashboard are restricted to Bedrock service access only. This eliminates the
# standing public endpoint (security + avoids SpringClean alerts).
info "Locking down AOSS network policy (removing public access) ..."
NET_POLICY_NAME="${ENVIRONMENT_NAME}-emr-kb-net"
NET_VERSION=$(aws opensearchserverless get-security-policy \
  --name "$NET_POLICY_NAME" --type network --region "$REGION" \
  --query "securityPolicyDetail.policyVersion" --output text)
aws opensearchserverless update-security-policy \
  --name "$NET_POLICY_NAME" --type network \
  --policy-version "$NET_VERSION" \
  --policy '[{"Rules":[{"ResourceType":"collection","Resource":["collection/'"${ENVIRONMENT_NAME}"'-emr-kb"]},{"ResourceType":"dashboard","Resource":["collection/'"${ENVIRONMENT_NAME}"'-emr-kb"]}],"AllowFromPublic":false,"SourceServices":["bedrock.amazonaws.com"]}]' \
  --region "$REGION" > /dev/null 2>&1 || true
ok "AOSS network policy locked down — no public access."

# --- Step 5: Create Bedrock Knowledge Base (AOSS vector store) ---
KB_PREFIX="${ENVIRONMENT_NAME}-emr-runbooks-kb"

# Find any existing ACTIVE KB with our prefix that uses the CURRENT AOSS collection
EXISTING_KB=""
for CANDIDATE in $(aws bedrock-agent list-knowledge-bases --region "$REGION" \
  --query "knowledgeBaseSummaries[?starts_with(name,'${KB_PREFIX}') && status=='ACTIVE'].knowledgeBaseId" --output text 2>/dev/null); do
  CANDIDATE_AOSS=$(aws bedrock-agent get-knowledge-base --knowledge-base-id "$CANDIDATE" --region "$REGION" \
    --query "knowledgeBase.storageConfiguration.opensearchServerlessConfiguration.collectionArn" --output text 2>/dev/null || echo "")
  if [ "$CANDIDATE_AOSS" = "$AOSS_ARN" ]; then
    EXISTING_KB="$CANDIDATE"
    break
  fi
done

if [ -n "$EXISTING_KB" ]; then
  KB_ID="$EXISTING_KB"
  ok "Bedrock KB already exists: $KB_ID"
else
  # Generate unique name to avoid collision with orphaned KBs
  KB_NAME="${KB_PREFIX}-$(date +%s)"
  info "Creating Bedrock Knowledge Base: $KB_NAME ..."
  KB_ID=$(aws bedrock-agent create-knowledge-base \
    --name "$KB_NAME" \
    --description "Semantic search over EMR/Spark runbooks" \
    --role-arn "$KB_ROLE_ARN" \
    --knowledge-base-configuration '{"type":"VECTOR","vectorKnowledgeBaseConfiguration":{"embeddingModelArn":"arn:aws:bedrock:'"$REGION"'::foundation-model/amazon.titan-embed-text-v1"}}' \
    --storage-configuration '{"type":"OPENSEARCH_SERVERLESS","opensearchServerlessConfiguration":{"collectionArn":"'"$AOSS_ARN"'","vectorIndexName":"'"$INDEX_NAME"'","fieldMapping":{"vectorField":"embedding","textField":"text","metadataField":"metadata"}}}' \
    --region "$REGION" \
    --query "knowledgeBase.knowledgeBaseId" --output text)
  ok "Bedrock KB created: $KB_ID"
  info "Waiting for KB to become ACTIVE ..."
  for i in $(seq 1 20); do
    KB_STATUS=$(aws bedrock-agent get-knowledge-base \
      --knowledge-base-id "$KB_ID" --region "$REGION" \
      --query "knowledgeBase.status" --output text 2>/dev/null || echo "UNKNOWN")
    if [ "$KB_STATUS" = "ACTIVE" ]; then ok "KB is ACTIVE."; break; fi
    sleep 5
  done
fi

# --- Step 6: Create Data Source + Sync ---
EXISTING_DS=$(aws bedrock-agent list-data-sources \
  --knowledge-base-id "$KB_ID" --region "$REGION" \
  --query "dataSourceSummaries[0].dataSourceId" --output text 2>/dev/null || echo "")

if [ -n "$EXISTING_DS" ] && [ "$EXISTING_DS" != "None" ]; then
  DS_ID="$EXISTING_DS"
  ok "Data source already exists: $DS_ID"
else
  info "Creating S3 data source ..."
  DS_ID=$(aws bedrock-agent create-data-source \
    --knowledge-base-id "$KB_ID" \
    --name "${ENVIRONMENT_NAME}-runbook-s3-source" \
    --data-source-configuration '{"type":"S3","s3Configuration":{"bucketArn":"arn:aws:s3:::'"$BUCKET"'","inclusionPrefixes":["runbooks/"]}}' \
    --region "$REGION" \
    --query "dataSource.dataSourceId" --output text)
  ok "Data source created: $DS_ID"
fi

info "Triggering KB sync ..."
aws bedrock-agent start-ingestion-job \
  --knowledge-base-id "$KB_ID" --data-source-id "$DS_ID" --region "$REGION" > /dev/null
ok "KB sync triggered."

echo ""
echo "============================================="
echo "  Deployment Complete"
echo "============================================="
echo "  S3 Bucket         : $BUCKET"
echo "  Knowledge Base ID : $KB_ID"
echo "  Data Source ID    : $DS_ID"
echo "  AOSS Collection   : $AOSS_ID (network: private, Bedrock-only)"
echo "============================================="
echo ""
echo "Next steps:"
echo "  1. bash scripts/deploy-shs.sh              (Spark History Server)"
echo "  2. bash scripts/deploy-mcp-server.sh       (Runbook MCP → AgentCore)"
echo "  3. bash scripts/deploy-shs-mcp-private.sh  (SHS MCP via Helm + NLB)"
echo "  4. Set up DevOps Agent Space (see docs/AGENT_SPACE_SETUP.md)"
