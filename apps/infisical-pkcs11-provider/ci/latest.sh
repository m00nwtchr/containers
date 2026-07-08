#!/usr/bin/env bash
version="$(curl -sX GET "https://api.github.com/repos/Infisical/infisical-pkcs-11/releases" | jq --raw-output 'first(.[]) | .tag_name' 2>/dev/null)"
version="${version#v}"
printf "%s" "${version}"