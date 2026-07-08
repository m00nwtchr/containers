FROM mirror.gcr.io/debian:bookworm-slim
ARG VERSION=0.10.0-2+b1

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      gnupg-pkcs11-scd=${VERSION} \
      ca-certificates \
      bash \
 && rm -rf /var/lib/apt/lists/*

COPY entrypoint.sh /usr/local/bin/entrypoint.sh

RUN mkdir -p /var/run/gnupg-pkcs11-scd \
             /var/lib/gnupg-pkcs11-scd \
 && chown 1000:1000 /var/lib/gnupg-pkcs11-scd \
 && chmod 1777 /var/run/gnupg-pkcs11-scd

VOLUME ["/var/run/gnupg-pkcs11-scd"]

USER 1000:1000

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]

HEALTHCHECK CMD sh -c 'for f in /var/run/gnupg-pkcs11-scd/gnupg-pkcs11-scd.*/agent.S; do [ -S "$f" ] && exit 0; done; exit 1'
