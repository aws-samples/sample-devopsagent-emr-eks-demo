#!/usr/bin/env bash
# Deploy Spark History Server on EKS
# Usage: bash scripts/deploy-shs.sh
set -euo pipefail

source config.env
REGION="${AWS_REGION:-us-east-1}"
STACK="${ENVIRONMENT_NAME:-dev}-emr-spark-alert-reduction"

info()  { echo -e "\033[36m[INFO]\033[0m  $*"; }
ok()    { echo -e "\033[32m[OK]\033[0m    $*"; }
error() { echo -e "\033[31m[ERROR]\033[0m $*" >&2; }

# Validate required configuration variables
for var in AWS_REGION ENVIRONMENT_NAME EKS_CLUSTER_NAME; do
  if [ -z "${!var:-}" ]; then error "$var not set in config.env"; exit 1; fi
done

BUCKET=$(aws cloudformation describe-stacks --stack-name "$STACK" --region "$REGION" \
  --query "Stacks[0].Outputs[?OutputKey=='DataBucketName'].OutputValue" --output text)

info "Deploying Spark History Server (bucket: $BUCKET) ..."

# Ensure spark-events prefix exists (SHS crashes if missing)
aws s3api put-object --bucket "$BUCKET" --key "spark-events/" --region "$REGION" > /dev/null 2>&1 || true

# Ensure kubeconfig is set
aws eks update-kubeconfig --name "$EKS_CLUSTER_NAME" --region "$REGION" 2>/dev/null

# Deploy SHS with bucket substitution
sed "s|S3_BUCKET_PLACEHOLDER|$BUCKET|g" spark-history-mcp/shs-deployment-v2.yaml | kubectl apply -f -

info "Waiting for SHS pod to be ready ..."
kubectl rollout status deployment/spark-history-server -n spark-history --timeout=120s

# Grant S3 read access to node roles (needed for SHS to read event logs)
info "Adding S3 read access to EKS node roles ..."
POLICY_DOC='{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Action": ["s3:GetObject", "s3:ListBucket"],
    "Resource": ["arn:aws:s3:::'"$BUCKET"'", "arn:aws:s3:::'"$BUCKET"'/*"]
  }]
}'

for ROLE_ARN in $(aws eks list-nodegroups --cluster-name "$EKS_CLUSTER_NAME" --region "$REGION" --query 'nodegroups' --output text | \
  xargs -I{} aws eks describe-nodegroup --cluster-name "$EKS_CLUSTER_NAME" --nodegroup-name {} --region "$REGION" \
    --query 'nodegroup.nodeRole' --output text 2>/dev/null); do
  ROLE_NAME=$(echo "$ROLE_ARN" | sed 's|.*/||')
  aws iam put-role-policy --role-name "$ROLE_NAME" --policy-name "SHSBucketAccess" \
    --policy-document "$POLICY_DOC" 2>/dev/null && \
    ok "Added S3 access to node role: $ROLE_NAME" || true
done

# Also handle Karpenter node roles if they exist
for ROLE_ARN in $(aws iam list-roles --query "Roles[?contains(RoleName,'karpenter') && contains(RoleName,'$EKS_CLUSTER_NAME')].Arn" --output text 2>/dev/null); do
  ROLE_NAME=$(echo "$ROLE_ARN" | sed 's|.*/||')
  aws iam put-role-policy --role-name "$ROLE_NAME" --policy-name "SHSBucketAccess" \
    --policy-document "$POLICY_DOC" 2>/dev/null && \
    ok "Added S3 access to Karpenter role: $ROLE_NAME" || true
done

ok "Spark History Server deployed."
echo ""
echo "  Verify: kubectl port-forward svc/spark-history-server -n spark-history 18080:18080"
echo "  Then:   curl -s http://localhost:18080/api/v1/applications | python3 -m json.tool"
