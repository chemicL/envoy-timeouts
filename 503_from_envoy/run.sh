#!/bin/bash

docker run -d --rm --name envoy-503 -p 10001:10001 -p 10000:10000 -p 10002:10002 envoy503:v1
