#!/usr/bin/env bash
# Fault: OOM via crossJoin
source "$(dirname "$0")/common.sh"
load_config
JOB_NAME="fault-oom-$(date +%Y%m%d-%H%M%S)"
info "Injecting OOM fault ..."
JOB_ID=$(submit_spark_job "sample-jobs/customer_analytics_bad_oom.py" "$JOB_NAME")
ok "Submitted: $JOB_ID"
wait_for_job "$JOB_ID"
print_next_steps "spark-oom-failure" "$JOB_ID"
