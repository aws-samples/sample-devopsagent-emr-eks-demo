#!/usr/bin/env bash
# Common functions for fault-injection demo scripts.
#
# Required IAM permissions for the caller: cloudformation:DescribeStacks,
# s3:PutObject, emr-containers:StartJobRun/DescribeJobRun, iam:PassRole.
# See docs/SECURITY_CONSIDERATIONS.md for shared responsibility and scoping.
set -euo pipefail

CONFIG_FILE="${CONFIG_FILE:-config.env}"

info()  { echo -e "\033[36m[INFO]\033[0m  $*"; }
warn()  { echo -e "\033[33m[WARN]\033[0m  $*"; }
error() { echo -e "\033[31m[ERROR]\033[0m $*" >&2; }
ok()    { echo -e "\033[32m[OK]\033[0m    $*"; }

load_config() {
  if [ ! -f "$CONFIG_FILE" ]; then error "$CONFIG_FILE not found."; exit 1; fi
  source "$CONFIG_FILE"
  REGION="${AWS_REGION:-us-east-1}"
  STACK="${ENVIRONMENT_NAME:-dev}-emr-spark-alert-reduction"
  # S3 bucket from CloudFormation
  S3_BUCKET=$(aws cloudformation describe-stacks \
    --stack-name "$STACK" --region "$REGION" \
    --query "Stacks[0].Outputs[?OutputKey=='DataBucketName'].OutputValue" \
    --output text 2>/dev/null || echo "")
  if [ -z "$S3_BUCKET" ] || [ "$S3_BUCKET" = "None" ]; then
    error "S3 bucket not found. Run 'make deploy' first."; exit 1
  fi
  # Verify bucket has Block Public Access enabled (deployed by infrastructure/template.yaml)
  BPA=$(aws s3api get-public-access-block --bucket "$S3_BUCKET" --region "$REGION" \
    --query 'PublicAccessBlockConfiguration.BlockPublicAcls' --output text 2>/dev/null || echo "false")
  if [ "$BPA" != "True" ]; then
    warn "S3 bucket $S3_BUCKET does not have Block Public Access enabled"
  fi
  # EMR params from config.env
  VIRTUAL_CLUSTER_ID="${EMR_VIRTUAL_CLUSTER_ID:-}"
  JOB_ROLE="${JOB_EXECUTION_ROLE_ARN:-}"
  if [ -z "$VIRTUAL_CLUSTER_ID" ]; then
    error "EMR_VIRTUAL_CLUSTER_ID not set in config.env"; exit 1
  fi
  if [ -z "$JOB_ROLE" ]; then
    error "JOB_EXECUTION_ROLE_ARN not set in config.env"; exit 1
  fi
}

submit_spark_job() {
  local job_file="$1"
  local job_name="$2"
  local s3_key="jobs/$(basename "$job_file")"

  aws s3 cp "$job_file" "s3://$S3_BUCKET/$s3_key" --region "$REGION" --quiet

  aws emr-containers start-job-run \
    --virtual-cluster-id "$VIRTUAL_CLUSTER_ID" \
    --name "$job_name" \
    --execution-role-arn "$JOB_ROLE" \
    --release-label "emr-7.0.0-latest" \
    --region "$REGION" \
    --job-driver '{
      "sparkSubmitJobDriver": {
        "entryPoint": "s3://'"$S3_BUCKET"'/'"$s3_key"'",
        "entryPointArguments": ["--output-path", "s3://'"$S3_BUCKET"'/output/"],
        "sparkSubmitParameters": "--conf spark.executor.instances=2 --conf spark.executor.memory=2G --conf spark.driver.memory=2G --conf spark.eventLog.enabled=true --conf spark.eventLog.dir=s3://'"$S3_BUCKET"'/spark-events/"
      }
    }' \
    --configuration-overrides '{
      "monitoringConfiguration": {
        "cloudWatchMonitoringConfiguration": {
          "logGroupName": "/emr-on-eks/'"${ENVIRONMENT_NAME:-dev}"'",
          "logStreamNamePrefix": "'"$job_name"'"
        },
        "s3MonitoringConfiguration": {
          "logUri": "s3://'"$S3_BUCKET"'/logs/"
        }
      }
    }' \
    --query "id" --output text
}

wait_for_job() {
  local id="$1" elapsed=0
  while [ $elapsed -lt 300 ]; do
    local st
    st=$(aws emr-containers describe-job-run \
      --virtual-cluster-id "$VIRTUAL_CLUSTER_ID" --id "$id" \
      --region "$REGION" --query "jobRun.state" --output text 2>/dev/null)
    case "$st" in
      COMPLETED) ok "Job $id completed."; return 0 ;;
      FAILED|CANCELLED) warn "Job $id: $st"; return 0 ;;
      *) sleep 15; elapsed=$((elapsed+15)); info "  $st (${elapsed}s)" ;;
    esac
  done
  warn "Timed out"
}

print_next_steps() {
  local scenario="$1" id="$2"
  echo ""
  echo "  Fault: $scenario | Job: $id"
  echo ""
}
