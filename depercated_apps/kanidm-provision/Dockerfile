FROM mirror.gcr.io/rust:alpine AS build
ARG VERSION
WORKDIR /src

RUN apk add --no-cache \
	ca-certificates \
	curl \
	build-base

RUN test -n "$VERSION" \
	&& curl -L "https://github.com/m00nwtchr/kanidm-provision/archive/refs/tags/v${VERSION}.tar.gz" \
	| tar -xz --strip-components=1

RUN cargo build --locked --release \
	&& strip target/release/kanidm-provision

FROM mirror.gcr.io/alpine:3.20

RUN apk add --no-cache bash jq curl kubectl
COPY --from=build /src/target/release/kanidm-provision /usr/local/bin/kanidm-provision

COPY ./apps/kanidm-provision/lib.jq /lib.jq
COPY ./apps/kanidm-provision/entrypoint.sh /entrypoint.sh

USER 65532:65532
ENTRYPOINT ["/entrypoint.sh"]
