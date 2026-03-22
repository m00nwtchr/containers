#!/usr/bin/env bash
set -euo pipefail

repo_url="https://dl-cdn.alpinelinux.org/alpine/v3.20/community/x86_64/APKINDEX.tar.gz"
version="$(curl -fsSL "${repo_url}" | tar -xzO APKINDEX | awk -F: '
  $1 == "P" { pkg = $2 }
  $1 == "V" && pkg == "kodi-wayland" { found = $2 }
  END { print found }
')"

printf "%s" "${version}"
