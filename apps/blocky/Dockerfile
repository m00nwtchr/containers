ARG VERSION

# stage 1: get binary from upstream
FROM ghcr.io/0xerr0r/blocky:v${VERSION} AS upstream

# stage 2: apply setcap using temporary container
FROM alpine:3.20 AS builder
RUN apk add --no-cache libcap
COPY --from=upstream /app/blocky /tmp/blocky
RUN setcap cap_net_bind_service=-ep /tmp/blocky

# stage 3: final scratch image
FROM scratch

USER 100
WORKDIR /app
COPY --from=builder /tmp/blocky /app/blocky
ENV BLOCKY_CONFIG_FILE=/app/config.yml

ENTRYPOINT ["/app/blocky"]
HEALTHCHECK --start-period=1m --timeout=3s CMD ["/app/blocky", "healthcheck"]
