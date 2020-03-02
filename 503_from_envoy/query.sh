#!/bin/bash

for i in {1..100}; do curl -s -o /dev/null -w "%{http_code} " localhost:10000; sleep 0.65; done;
