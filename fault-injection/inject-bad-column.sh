#!/usr/bin/env bash
# Fault: AnalysisException — non-existent column
source "$(dirname "$0")/common.sh"
load_config
JOB_NAME="fault-column-$(date +%Y%m%d-%H%M%S)"
info "Injecting bad column fault ..."
JOB_ID=$(submit_spark_job "sample-jobs/customer_analytics_bad_column.py" "$JOB_NAME")
ok "Submitted: $JOB_ID"
wait_for_job "$JOB_ID"
print_next_steps "spark-analysis-exception" "$JOB_ID"
