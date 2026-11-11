#!/bin/sh
set -eu

log_file=/tmp/foundry-mcp.log

if node /app/scripts/configure-credentials.mjs 2>"$log_file"; then
  :
else
  status=$?
  cat "$log_file" >&2 || true
  exit "$status"
fi

# Keep PID 1's stderr stream open for Kubernetes attach while keeping the
# server's diagnostics out of the MCP stdout/stderr protocol streams.
server_pid=
signal_received=0

forward_signal() {
  signal_received=1
  if [ -n "$server_pid" ]; then
    kill -TERM "$server_pid" 2>/dev/null || true
  fi
}

trap forward_signal TERM INT

exec 3<&0
node /app/build/server.js <&3 2>>"$log_file" &
server_pid=$!
exec 3<&-

if [ "$signal_received" -ne 0 ]; then
  kill -TERM "$server_pid" 2>/dev/null || true
fi

set +e
wait "$server_pid"
status=$?
if [ "$signal_received" -ne 0 ]; then
  wait "$server_pid"
  child_status=$?
  if [ "$child_status" -ne 127 ]; then
    status=$child_status
  fi
fi
set -e

trap - TERM INT

if [ "$status" -ne 0 ]; then
  cat "$log_file" >&2 || true
fi

exit "$status"
