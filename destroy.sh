#!/usr/bin/env bash
# Cleanup all deployed resources for the Amazon EMR Spark Alert Reduction sample.
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0
#
# Verification checklist after running this script:
#   aws cloudformation describe-stacks --stack-name dev-emr-spark-alert-reduction --region <region>
#     (expect: stack not found after successful destroy)
#   aws iam list-role-policies --role-name <emr-execution-role>
#     (expect: no SHSBucketAccess, CloudWatchLogsAccess, RunbookBucketAccess entries)
#   kubectl get ns spark-history
#     (expect: namespace deleted or empty)
#   aws bedrock-agent list-knowledge-bases --region <region>
#     (expect: no dev-emr-runbooks-kb entries)
#   aws cognito-idp list-user-pools --max-results 20 --region <region>
#     (expect: no emr-spark-mcp-pool entries)
#
# Data protection: this script empties the Amazon S3 data bucket (runbooks,
# Spark event logs, job output) before deleting it via CloudFormation. Ensure
# you have backups of any data you need before running this script.
set -euo pipefail

source config.env 2>/dev/null || true
REGION="${AWS_REGION:-us-east-1}"
ENV="${ENVIRONMENT_NAME:-dev}"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text 2>/dev/null || echo "unknown")

info() { echo -e "\033[36m[INFO]\033[0m  $*"; }
ok()   { echo -e "\033[32m[OK]\033[0m    $*"; }

# ── IAM policy patches (added by deploy) ──────────────────────────────────
info "Removing IAM policy patches..."

# EMR execution role patches (from patch-emr-role.sh)
if [ -n "${JOB_EXECUTION_ROLE_ARN:-}" ]; then
  EMR_ROLE_NAME=$(echo "$JOB_EXECUTION_ROLE_ARN" | sed 's|.*/||')
  aws iam delete-role-policy --role-name "$EMR_ROLE_NAME" --policy-name "CloudWatchLogsAccess" 2>/dev/null || true
  aws iam delete-role-policy --role-name "$EMR_ROLE_NAME" --policy-name "RunbookBucketAccess" 2>/dev/null || true
  ok "EMR execution role policies removed: $EMR_ROLE_NAME"
fi

# Node role S3 patches (from deploy-shs.sh)
if [ -n "${EKS_CLUSTER_NAME:-}" ]; then
  for ROLE_ARN in $(aws eks list-nodegroups --cluster-name "$EKS_CLUSTER_NAME" --region "$REGION" --query 'nodegroups' --output text 2>/dev/null | \
    xargs -I{} aws eks describe-nodegroup --cluster-name "$EKS_CLUSTER_NAME" --nodegroup-name {} --region "$REGION" \
      --query 'nodegroup.nodeRole' --output text 2>/dev/null); do
    ROLE_NAME=$(echo "$ROLE_ARN" | sed 's|.*/||')
    aws iam delete-role-policy --role-name "$ROLE_NAME" --policy-name "SHSBucketAccess" 2>/dev/null || true
  done
  for ROLE_ARN in $(aws iam list-roles --query "Roles[?contains(RoleName,'karpenter') && contains(RoleName,'$EKS_CLUSTER_NAME')].Arn" --output text 2>/dev/null); do
    ROLE_NAME=$(echo "$ROLE_ARN" | sed 's|.*/||')
    aws iam delete-role-policy --role-name "$ROLE_NAME" --policy-name "SHSBucketAccess" 2>/dev/null || true
  done
  ok "Node role S3 policies removed"
fi

# ── SHS MCP (Helm release + NLB) ──────────────────────────────────────────
info "Deleting SHS MCP Helm release..."
helm uninstall shs-mcp -n spark-history 2>/dev/null || true
ok "SHS MCP Helm release deleted"

# ── Old API Gateway + ALB (if exists from previous deployment) ────────────
info "Cleaning up old API Gateway + ALB (if any)..."
API_ID=$(aws apigatewayv2 get-apis --region "$REGION" --query "Items[?Name=='shs-mcp-api'].ApiId" --output text 2>/dev/null)
[ -n "$API_ID" ] && [ "$API_ID" != "None" ] && aws apigatewayv2 delete-api --api-id "$API_ID" --region "$REGION" 2>/dev/null || true

VPC_LINK_ID=$(aws apigatewayv2 get-vpc-links --region "$REGION" --query "Items[?Name=='shs-mcp-vpc-link'].VpcLinkId" --output text 2>/dev/null)
[ -n "$VPC_LINK_ID" ] && [ "$VPC_LINK_ID" != "None" ] && aws apigatewayv2 delete-vpc-link --vpc-link-id "$VPC_LINK_ID" --region "$REGION" 2>/dev/null || true

ALB_ARN=$(aws elbv2 describe-load-balancers --region "$REGION" --query "LoadBalancers[?LoadBalancerName=='shs-mcp-alb'].LoadBalancerArn" --output text 2>/dev/null)
if [ -n "$ALB_ARN" ] && [ "$ALB_ARN" != "None" ]; then
  for LISTENER in $(aws elbv2 describe-listeners --load-balancer-arn "$ALB_ARN" --region "$REGION" --query 'Listeners[].ListenerArn' --output text 2>/dev/null); do
    aws elbv2 delete-listener --listener-arn "$LISTENER" --region "$REGION" 2>/dev/null || true
  done
  aws elbv2 delete-load-balancer --load-balancer-arn "$ALB_ARN" --region "$REGION" 2>/dev/null || true
  sleep 15
fi

TG_ARN=$(aws elbv2 describe-target-groups --region "$REGION" --query "TargetGroups[?TargetGroupName=='shs-mcp-tg'].TargetGroupArn" --output text 2>/dev/null)
[ -n "$TG_ARN" ] && [ "$TG_ARN" != "None" ] && aws elbv2 delete-target-group --target-group-arn "$TG_ARN" --region "$REGION" 2>/dev/null || true
ok "Old API Gateway + ALB cleaned up"

# ── CloudWatch log group ──────────────────────────────────────────────────
info "Deleting CloudWatch log group..."
aws logs delete-log-group --log-group-name "/emr-on-eks/${ENV}" --region "$REGION" 2>/dev/null || true
ok "CloudWatch log group deleted (or didn't exist)"

# ── Private Connection (if exists) ────────────────────────────────────────
info "Manual cleanup required in DevOps Agent console:"
info "  1. Delete MCP Server registrations (Runbook MCP + SHS MCP)"
info "  2. Delete Private Connection (shs-mcp-private)"
info "  3. Delete Agent Space (if no longer needed)"

# ── Private Connection Security Group ─────────────────────────────────────
info "Cleaning up Private Connection security group..."
if [ -n "${EKS_CLUSTER_NAME:-}" ]; then
  SG_NAME="${ENV}-shs-mcp-private-connection-sg"
  VPC_ID=$(aws eks describe-cluster --name "$EKS_CLUSTER_NAME" --region "$REGION" \
    --query 'cluster.resourcesVpcConfig.vpcId' --output text 2>/dev/null || echo "")
  CLUSTER_SG=$(aws eks describe-cluster --name "$EKS_CLUSTER_NAME" --region "$REGION" \
    --query 'cluster.resourcesVpcConfig.clusterSecurityGroupId' --output text 2>/dev/null || echo "")
  PC_SG=$(aws ec2 describe-security-groups --region "$REGION" \
    --filters "Name=group-name,Values=$SG_NAME" "Name=vpc-id,Values=$VPC_ID" \
    --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null || echo "None")
  if [ -n "$PC_SG" ] && [ "$PC_SG" != "None" ]; then
    # Remove inbound rule from cluster SG
    aws ec2 revoke-security-group-ingress --group-id "$CLUSTER_SG" \
      --protocol tcp --port 18889 --source-group "$PC_SG" --region "$REGION" 2>/dev/null || true
    # Delete the SG
    if aws ec2 delete-security-group --group-id "$PC_SG" --region "$REGION" 2>/dev/null; then
      ok "Private Connection SG deleted: $PC_SG"
    else
      info "Could not delete SG $PC_SG — delete Private Connection from DevOps Agent console first, then retry"
    fi
  else
    info "No Private Connection SG found"
  fi
fi

# ── EKS resources ─────────────────────────────────────────────────────────
info "Deleting EKS resources (SHS MCP + SHS)..."
kubectl delete namespace spark-history --ignore-not-found 2>/dev/null || true
ok "EKS resources deleted"

# ── Bedrock Knowledge Base ────────────────────────────────────────────────
info "Deleting Bedrock Knowledge Base..."
KB_NAME="${ENV}-emr-runbooks-kb"
KB_ID=$(aws bedrock-agent list-knowledge-bases --region "$REGION" \
  --query "knowledgeBaseSummaries[?name=='${KB_NAME}'].knowledgeBaseId" --output text 2>/dev/null || echo "")
if [ -n "$KB_ID" ] && [ "$KB_ID" != "None" ]; then
  # Set data sources to RETAIN policy, then delete (avoids DELETE_UNSUCCESSFUL when AOSS is already gone)
  for DS_ID in $(aws bedrock-agent list-data-sources --knowledge-base-id "$KB_ID" --region "$REGION" \
    --query "dataSourceSummaries[].dataSourceId" --output text 2>/dev/null); do
    DS_NAME=$(aws bedrock-agent get-data-source --knowledge-base-id "$KB_ID" --data-source-id "$DS_ID" --region "$REGION" \
      --query "dataSource.name" --output text 2>/dev/null || echo "ds")
    DS_CONFIG=$(aws bedrock-agent get-data-source --knowledge-base-id "$KB_ID" --data-source-id "$DS_ID" --region "$REGION" \
      --query "dataSource.dataSourceConfiguration" --output json 2>/dev/null || echo "{}")
    aws bedrock-agent update-data-source --knowledge-base-id "$KB_ID" --data-source-id "$DS_ID" \
      --name "$DS_NAME" --data-source-configuration "$DS_CONFIG" \
      --data-deletion-policy RETAIN --region "$REGION" > /dev/null 2>&1 || true
    aws bedrock-agent delete-data-source --knowledge-base-id "$KB_ID" --data-source-id "$DS_ID" --region "$REGION" 2>/dev/null || true
  done
  sleep 5
  aws bedrock-agent delete-knowledge-base --knowledge-base-id "$KB_ID" --region "$REGION" 2>/dev/null || true
  ok "Bedrock KB deleted: $KB_ID"
else
  info "No Bedrock KB found"
fi

# ── Cognito ───────────────────────────────────────────────────────────────
info "Deleting Cognito user pool..."
POOL_ID=$(aws cognito-idp list-user-pools --max-results 20 --region "$REGION" \
  --query "UserPools[?Name=='emr-spark-mcp-pool'].Id" --output text 2>/dev/null || echo "")
if [ -n "$POOL_ID" ] && [ "$POOL_ID" != "None" ]; then
  # Delete domain if exists
  aws cognito-idp delete-user-pool-domain --user-pool-id "$POOL_ID" --domain "emr-spark-mcp-${ACCOUNT_ID}" --region "$REGION" 2>/dev/null || true
  aws cognito-idp delete-user-pool --user-pool-id "$POOL_ID" --region "$REGION" 2>/dev/null || true
  ok "Cognito pool deleted: $POOL_ID"
else
  info "No Cognito pool found"
fi

# ── CloudFormation stack (S3, AOSS, EventBridge, SNS) ─────────────────────
info "Deleting CloudFormation stack..."
STACK="${ENV}-emr-spark-alert-reduction"
# Empty S3 buckets first (CFN can't delete non-empty buckets)
empty_versioned_bucket() {
  local bucket="$1"
  [ -z "$bucket" ] || [ "$bucket" = "None" ] && return
  info "Emptying S3 bucket: $bucket"
  aws s3 rm "s3://$bucket" --recursive --region "$REGION" 2>/dev/null || true
  # Delete all object versions and delete markers (versioned bucket)
  python3 - "$bucket" "$REGION" << 'PY' || true
import sys, boto3
bucket, region = sys.argv[1], sys.argv[2]
s3 = boto3.client('s3', region_name=region)
paginator = s3.get_paginator('list_object_versions')
total = 0
for page in paginator.paginate(Bucket=bucket):
    versions = page.get('Versions', []) + page.get('DeleteMarkers', [])
    if not versions: continue
    for i in range(0, len(versions), 1000):
        batch = versions[i:i+1000]
        objs = [{'Key': v['Key'], 'VersionId': v['VersionId']} for v in batch]
        s3.delete_objects(Bucket=bucket, Delete={'Objects': objs, 'Quiet': True})
        total += len(batch)
if total:
    print(f"  Deleted {total} versions from {bucket}")
PY
}
BUCKET=$(aws cloudformation describe-stacks --stack-name "$STACK" --region "$REGION" \
  --query "Stacks[0].Outputs[?OutputKey=='DataBucketName'].OutputValue" --output text 2>/dev/null || echo "")
LOGBUCKET=$(aws cloudformation describe-stacks --stack-name "$STACK" --region "$REGION" \
  --query "Stacks[0].Outputs[?OutputKey=='LoggingBucketName'].OutputValue" --output text 2>/dev/null || echo "")
empty_versioned_bucket "$BUCKET"
empty_versioned_bucket "$LOGBUCKET"
aws cloudformation delete-stack --stack-name "$STACK" --region "$REGION" 2>/dev/null || true
ok "CFN stack deletion initiated (takes ~5 min for AOSS)"

# ── Amazon Bedrock AgentCore Runtime ─────────────────────────────────────────────────────
info "Deleting Amazon Bedrock AgentCore Runtime..."
aws cloudformation delete-stack --stack-name AgentCore-runbookmcp-default --region us-east-1 2>/dev/null || true
ok "Amazon Bedrock AgentCore CFN stack deletion initiated"

echo ""
echo "============================================="
echo "  Cleanup Complete"
echo "============================================="
echo "  Note: CFN stack deletion may take ~5 min"
echo "  Note: EKS cluster (data-on-eks) is NOT deleted"
echo "        To delete: cd data-on-eks/analytics/terraform/emr-eks-karpenter && terraform destroy"
echo "============================================="
