ARG VERSION

FROM alpine:3.20
ARG VERSION

RUN apk add --no-cache \
  libseat \
  seatd-launch \
  weston=${VERSION} \
  weston-backend-drm=${VERSION} \
  weston-backend-headless=${VERSION} \
  weston-clients=${VERSION}

RUN addgroup -S app && adduser -S -D -G app app

RUN mkdir -p /run/user && chmod 1777 /run/user

COPY ./apps/weston/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

USER app

ENTRYPOINT ["/entrypoint.sh"]
