FROM mirror.gcr.io/debian:trixie-slim AS build
ARG VERSION=0.0.3
ARG TARGETARCH

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      curl \
      ca-certificates \
 && rm -rf /var/lib/apt/lists/*

RUN set -eux; \
    base="https://github.com/Infisical/infisical-pkcs-11/releases/download/v${VERSION}"; \
    asset="libinfisical-pkcs11-linux-${TARGETARCH}.so.tar.gz"; \
    curl -fsSL -o checksums.txt "${base}/checksums-sha256.txt"; \
    curl -fsSL -o "${asset}"  "${base}/${asset}"; \
    grep " ${asset}\$" checksums.txt | sha256sum -c -; \
    mkdir -p /out; \
    tar -xzOf "${asset}" > /out/libinfisical-pkcs11.so; \
    chmod 0755 /out/libinfisical-pkcs11.so

FROM scratch

COPY --from=build /out/libinfisical-pkcs11.so /libinfisical-pkcs11.so