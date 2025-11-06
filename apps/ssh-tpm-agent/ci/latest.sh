#!/usr/bin/env bash
version="$(curl -sX GET "https://api.github.com/repos/Foxboron/ssh-tpm-agent/releases" | jq --raw-output 'first(.[]) | .tag_name' 2>/dev/null)"
version="${version#*v}"
printf "%s" "${version}"
