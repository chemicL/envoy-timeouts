#!/bin/bash

printf "Stats:\n---\n\n"
PATTERNS=(
  "upstream_cx_destroy_remote_with_active_rq"
  "cluster\.target_proxy_cluster\.upstream_rq_503"
  "cluster\.service_google\.upstream_rq_.xx"
)
for p in ${PATTERNS[*]}; do curl -s localhost:10002/stats | grep "$p"; done;
