#!/usr/bin/env bash
# Submit a PySpark job to EMR on EKS
# Usage: ./scripts/submit_job.sh [job_file]
set -euo pipefail

JOB_FILE="${1:-sample-jobs/customer_analytics.py}"
source config.env

REGION="${AWS_REGION:-us-east-1}"
STACK="${ENVIRONMENT_NAME:-dev}-emr-spark-alert-reduction"
S3_BUCKET=$(aws cloudformation describe-stacks \
  --stack-name "$STACK" --region "$REGION" \
  --query "Stacks[0].Outputs[?OutputKey=='DataBucketName'].OutputValue" --output text)

S3_KEY="jobs/$(basename "$JOB_FILE")"
JOB_NAME="spark-job-$(date +%Y%m%d-%H%M%S)"

echo "Uploading $JOB_FILE → s3://$S3_BUCKET/$S3_KEY"
aws s3 cp "$JOB_FILE" "s3://$S3_BUCKET/$S3_KEY" --region "$REGION"

echo "Submitting $JOB_NAME ..."
JOB_ID=$(aws emr-containers start-job-run \
  --virtual-cluster-id "$EMR_VIRTUAL_CLUSTER_ID" \
  --name "$JOB_NAME" \
  --execution-role-arn "$JOB_EXECUTION_ROLE_ARN" \
  --release-label "emr-7.0.0-latest" --region "$REGION" \
  --job-driver '{
    "sparkSubmitJobDriver": {
      "entryPoint": "s3://'"$S3_BUCKET"'/'"$S3_KEY"'",
      "entryPointArguments": ["--output-path", "s3://'"$S3_BUCKET"'/output/'"$JOB_NAME"'"],
      "sparkSubmitParameters": "--conf spark.executor.instances=2 --conf spark.executor.memory=2G --conf spark.driver.memory=2G --conf spark.eventLog.enabled=true --conf spark.eventLog.dir=s3://'"$S3_BUCKET"'/spark-events/"
    }
  }' \
  --configuration-overrides '{
    "monitoringConfiguration": {
      "cloudWatchMonitoringConfiguration": {
        "logGroupName": "/emr-on-eks/'"${ENVIRONMENT_NAME:-dev}"'",
        "logStreamNamePrefix": "'"$JOB_NAME"'"
      },
      "s3MonitoringConfiguration": {
        "logUri": "s3://'"$S3_BUCKET"'/logs/"
      }
    }
  }' \
  --query "id" --output text)

echo "Job: $JOB_ID | Cluster: $EMR_VIRTUAL_CLUSTER_ID"
