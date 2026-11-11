#!/bin/sh
set -eu

node /app/scripts/configure-credentials.mjs
exec node /app/build/server.js 2>/tmp/foundry-mcp.log
