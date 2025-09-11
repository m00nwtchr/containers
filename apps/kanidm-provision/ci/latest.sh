#!/usr/bin/env bash
version="$(curl -sX GET "https://api.github.com/repos/oddlama/kanidm-provision/tags" | jq --raw-output 'first(.[]) | .name' 2>/dev/null)"
version="${version#*v}"
printf "%s" "${version}"
