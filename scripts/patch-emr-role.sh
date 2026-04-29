#!/usr/bin/env bash
# Post-Phase-1 setup: Add IAM policies that the data-on-eks blueprint doesn't include
# Run this AFTER terraform apply and BEFORE make deploy
set -euo pipefail

source config.env
REGION="${AWS_REGION:-us-east-1}"

info()  { echo -e "\033[36m[INFO]\033[0m  $*"; }
ok()    { echo -e "\033[32m[OK]\033[0m    $*"; }
error() { echo -e "\033[31m[ERROR]\033[0m $*" >&2; }

if [ -z "${JOB_EXECUTION_ROLE_ARN:-}" ]; then
  error "JOB_EXECUTION_ROLE_ARN not set in config.env"
  exit 1
fi

ROLE_NAME=$(echo "$JOB_EXECUTION_ROLE_ARN" | sed 's|.*/||')
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
BUCKET="${ENVIRONMENT_NAME:-dev}-emr-spark-${ACCOUNT_ID}"

info "Adding Amazon CloudWatch Logs access to Amazon EMR execution role: $ROLE_NAME ..."
# Scoped to Amazon EMR on EKS and Amazon EMR containers log groups only (least privilege).
aws iam put-role-policy --role-name "$ROLE_NAME" \
  --policy-name "CloudWatchLogsAccess" \
  --policy-document '{
    "Version": "2012-10-17",
    "Statement": [{
      "Effect": "Allow",
      "Action": ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"],
      "Resource": [
        "arn:aws:logs:'"$REGION"':'"$ACCOUNT_ID"':log-group:/emr-on-eks/*",
        "arn:aws:logs:'"$REGION"':'"$ACCOUNT_ID"':log-group:/emr-on-eks/*:*",
        "arn:aws:logs:'"$REGION"':'"$ACCOUNT_ID"':log-group:/aws/emr-containers/*",
        "arn:aws:logs:'"$REGION"':'"$ACCOUNT_ID"':log-group:/aws/emr-containers/*:*"
      ]
    }]
  }'
ok "Amazon CloudWatch Logs access added."

info "Adding Amazon S3 access for runbook bucket to Amazon EMR execution role ..."
# Split into two statements (least privilege):
#   - Read: whole bucket (EMR may read from any prefix: runbooks/, jobs/, output/)
#   - Write: only prefixes Amazon EMR actually writes to (Spark event logs, driver/executor logs,
#            job output, and the copy of the submitted PySpark script).
aws iam put-role-policy --role-name "$ROLE_NAME" \
  --policy-name "RunbookBucketAccess" \
  --policy-document '{
    "Version": "2012-10-17",
    "Statement": [
      {
        "Sid": "ReadAll",
        "Effect": "Allow",
        "Action": ["s3:GetObject", "s3:ListBucket"],
        "Resource": [
          "arn:aws:s3:::'"$BUCKET"'",
          "arn:aws:s3:::'"$BUCKET"'/*"
        ]
      },
      {
        "Sid": "WriteScopedPrefixes",
        "Effect": "Allow",
        "Action": ["s3:PutObject", "s3:DeleteObject"],
        "Resource": [
          "arn:aws:s3:::'"$BUCKET"'/spark-events/*",
          "arn:aws:s3:::'"$BUCKET"'/logs/*",
          "arn:aws:s3:::'"$BUCKET"'/output/*",
          "arn:aws:s3:::'"$BUCKET"'/jobs/*"
        ]
      }
    ]
  }'
ok "Amazon S3 bucket access added."

echo ""
ok "Amazon EMR execution role patched. You can now run: make deploy"
