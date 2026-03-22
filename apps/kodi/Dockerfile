ARG VERSION

FROM alpine:3.20
ARG VERSION

RUN apk add --no-cache \
  mesa-dri-gallium \
  mesa-egl \
  mesa-gles \
  kodi-wayland=${VERSION}

RUN addgroup -S app && adduser -S -D -G app app

RUN mkdir -p /tmp/run /data /cache && chmod 1777 /tmp/run /data /cache

ENV HOME=/data \
  XDG_CONFIG_HOME=/etc \
  XDG_DATA_HOME=/data \
  XDG_STATE_HOME=/data \
  XDG_CACHE_HOME=/cache \
  XDG_RUNTIME_DIR=/tmp/run

COPY ./apps/kodi/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

USER app

ENTRYPOINT ["/entrypoint.sh"]
