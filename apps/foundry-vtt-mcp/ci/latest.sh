#!/usr/bin/env bash
set -euo pipefail

version="$(curl -fsSL "https://api.github.com/repos/TheStranjer/foundry-vtt-mcp/commits/master" | jq --raw-output '.sha')"

if [ -z "${version}" ] || [ "${version}" = "null" ]; then
  echo "ERROR: failed to fetch the latest upstream commit" >&2
  exit 1
fi

printf "%s" "${version}"
