#!/bin/sh
set -eu

node /app/scripts/configure-credentials.mjs 2>/tmp/foundry-mcp.log

# Keep PID 1's stderr stream open for Kubernetes attach while keeping the
# server's diagnostics out of the MCP stdout/stderr protocol streams.
node /app/build/server.js 2>>/tmp/foundry-mcp.log &
server_pid=$!
wait "$server_pid"
