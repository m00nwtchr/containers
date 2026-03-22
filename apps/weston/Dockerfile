ARG VERSION

FROM alpine:3.20
ARG VERSION

RUN apk add --no-cache \
  libseat \
  mesa-dri-gallium \
  seatd-launch \
  weston=${VERSION} \
  weston-backend-drm=${VERSION} \
  weston-backend-headless=${VERSION} \
  weston-clients=${VERSION}

RUN addgroup -S app && adduser -S -D -G app app

RUN mkdir -p /tmp/run /data /cache && chmod 1777 /tmp/run /data /cache

ENV XDG_CONFIG_HOME=/etc \
  XDG_DATA_HOME=/data \
  XDG_STATE_HOME=/data \
  XDG_CACHE_HOME=/cache \
  XDG_RUNTIME_DIR=/tmp/run

COPY ./apps/weston/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

USER app

ENTRYPOINT ["/entrypoint.sh"]
