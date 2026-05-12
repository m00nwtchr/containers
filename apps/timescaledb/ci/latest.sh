#!/usr/bin/env bash
set -euo pipefail

version="$(curl -fsSL "https://api.github.com/repos/timescale/timescaledb/releases/latest" | jq -r '.tag_name // empty' | sed 's/^refs\/tags\///')"

if [ -z "${version}" ]; then
  echo "ERROR: failed to fetch latest version" >&2
  exit 1
fi

printf "%s" "${version}"
