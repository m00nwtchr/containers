# syntax=docker/dockerfile:1

FROM node:24-alpine AS builder

RUN apk add --no-cache git

WORKDIR /app

# Defaults to the upstream master branch; may be overridden with a tag or commit.
ARG FOUNDRY_MCP_REF=master

RUN git init -q \
    && git remote add origin https://github.com/TheStranjer/foundry-vtt-mcp.git \
    && git fetch --depth 1 origin "${FOUNDRY_MCP_REF}" \
    && git checkout -q --detach FETCH_HEAD

RUN npm ci --ignore-scripts \
    && npm run build \
    && npm prune --omit=dev --ignore-scripts

FROM node:24-alpine

WORKDIR /app

ENV NODE_ENV=production \
    FOUNDRY_CREDENTIALS=/tmp/foundry_credentials.json

COPY --from=builder /app/build ./build
COPY --from=builder /app/node_modules ./node_modules
COPY --from=builder /app/package.json ./package.json

COPY scripts/configure-credentials.mjs ./scripts/
COPY --chmod=0755 scripts/entrypoint.sh ./scripts/

USER node

ENTRYPOINT ["/app/scripts/entrypoint.sh"]
