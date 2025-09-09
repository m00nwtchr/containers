#!/bin/bash

set -e

export BW_PORT=${BW_PORT:=8087}
export BITWARDENCLI_APPDATA_DIR=$(mktemp -d)
export HOME=$(mktemp -d)

bw config server "${BW_HOST}"

export BW_SESSION=$(bw login ${BW_USER} --passwordenv BW_PASSWORD --raw)

bw unlock --check

echo "Running 'bw server' on port ${BW_PORT}"
bw serve --port ${BW_PORT} --hostname :: #--disable-origin-protection
