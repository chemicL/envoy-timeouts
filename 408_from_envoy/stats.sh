#!/bin/bash

printf "Stats:\n---\n\n"
PATTERNS=(
  "^http\.ingress_http_self\.downstream_rq_4xx"
  "^http\.ingress_http\.downstream_rq_.xx"
)
for p in ${PATTERNS[*]}; do curl -s localhost:10002/stats | grep "$p"; done;
