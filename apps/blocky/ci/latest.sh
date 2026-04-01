#!/usr/bin/env bash
version="$(curl -sX GET "https://api.github.com/repos/0xERR0R/blocky/releases" | jq --raw-output 'first(.[] | select(.tag_name | startswith("v"))) | .tag_name' 2>/dev/null)"
version="${version#*v}"
printf "%s" "${version}"
