#!/usr/bin/env bash
# Fault: 95% data skew to one partition
source "$(dirname "$0")/common.sh"
load_config
JOB_NAME="fault-skew-$(date +%Y%m%d-%H%M%S)"
info "Injecting data skew fault ..."
JOB_ID=$(submit_spark_job "sample-jobs/customer_analytics_bad_skew.py" "$JOB_NAME")
ok "Submitted: $JOB_ID"
wait_for_job "$JOB_ID"
print_next_steps "spark-data-skew" "$JOB_ID"
