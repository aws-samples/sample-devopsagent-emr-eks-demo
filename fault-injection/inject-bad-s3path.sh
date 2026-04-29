#!/usr/bin/env bash
# Fault: Non-existent S3 path — immediate failure
source "$(dirname "$0")/common.sh"
load_config
JOB_NAME="fault-s3path-$(date +%Y%m%d-%H%M%S)"
info "Injecting bad S3 path fault ..."
JOB_ID=$(submit_spark_job "sample-jobs/customer_analytics_bad_s3path.py" "$JOB_NAME")
ok "Submitted: $JOB_ID"
wait_for_job "$JOB_ID"
print_next_steps "emr-job-submission-failure" "$JOB_ID"
