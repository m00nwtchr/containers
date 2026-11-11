#!/bin/sh
set -eu

log_file=/tmp/foundry-mcp.log

if node /app/scripts/configure-credentials.mjs 2>"$log_file"; then
  :
else
  status=$?
  cat "$log_file" >&2
  exit "$status"
fi

# Keep PID 1's stderr stream open for Kubernetes attach while keeping the
# server's diagnostics out of the MCP stdout/stderr protocol streams.
exec 3<&0
node /app/build/server.js <&3 2>>"$log_file" &
server_pid=$!
exec 3<&-

forward_signal() {
  kill -TERM "$server_pid" 2>/dev/null || true
}

trap forward_signal TERM INT

set +e
wait "$server_pid"
status=$?
set -e

trap - TERM INT

if [ "$status" -ne 0 ]; then
  cat "$log_file" >&2
fi

exit "$status"
