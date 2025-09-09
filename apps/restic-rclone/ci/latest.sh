#!/usr/bin/env bash
restic="$(curl -sX GET "https://api.github.com/repos/restic/restic/releases" | jq --raw-output 'first(.[]) | .tag_name' 2>/dev/null)"
restic="${restic#*v}"

rclone="$(curl -sX GET "https://api.github.com/repos/rclone/rclone/releases" | jq --raw-output 'first(.[]) | .tag_name' 2>/dev/null)"
rclone="${rclone#*v}"

printf "%s-%s" "${restic}" "${rclone}"
