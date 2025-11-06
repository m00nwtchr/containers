FROM mirror.gcr.io/golang:alpine AS build
ARG VERSION
WORKDIR /src

RUN test -n "$VERSION" \
	&& go install "github.com/foxboron/ssh-tpm-agent/cmd/...@v${VERSION}"

# FROM mirror.gcr.io/alpine:3.20

# RUN apk add --no-cache bash jq curl kubectl
# COPY --from=build /src/target/release/kanidm-provision /usr/local/bin/kanidm-provision

# COPY ./apps/kanidm-provision/lib.jq /lib.jq
# COPY ./apps/kanidm-provision/entrypoint.sh /entrypoint.sh

USER 65532:65532
# ENTRYPOINT ["/entrypoint.sh"]
