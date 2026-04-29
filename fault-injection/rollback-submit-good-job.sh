#!/usr/bin/env bash
# Rollback: Submit good job to verify healthy state
source "$(dirname "$0")/common.sh"
load_config
JOB_NAME="good-baseline-$(date +%Y%m%d-%H%M%S)"
info "Submitting good job ..."
JOB_ID=$(submit_spark_job "sample-jobs/customer_analytics.py" "$JOB_NAME")
ok "Submitted: $JOB_ID"
wait_for_job "$JOB_ID"
ok "System healthy."
