#!/bin/bash

printf "Stats:\n---\n\n"
PATTERNS=(
  "cluster\.target_proxy_cluster\.upstream_rq_504"
  "^http\.ingress_http\.downstream_rq_5xx"
  "^http\.ingress_http_self\.downstream_rq_5xx"
)
for p in ${PATTERNS[*]}; do curl -s localhost:10002/stats | grep "$p"; done;
