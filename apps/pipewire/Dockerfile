ARG VERSION

FROM alpine:3.20
ARG VERSION

RUN apk add --no-cache \
  pipewire=${VERSION} \
  pipewire-pulse \
  pipewire-tools \
  wireplumber

RUN addgroup -S app && adduser -S -D -G app app

COPY ./apps/pipewire/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

USER app

ENTRYPOINT ["/entrypoint.sh"]
