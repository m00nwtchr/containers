ARG VERSION

FROM alpine:3.20
ARG VERSION

RUN apk add --no-cache \
  kodi-wayland=${VERSION}

RUN addgroup -S app && adduser -S -D -G app app

RUN mkdir -p /data && chown -R app:app /data

COPY ./apps/kodi/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

USER app

ENTRYPOINT ["/entrypoint.sh"]
