FROM mirror.gcr.io/golang:alpine AS build
ARG VERSION

RUN test -n "$VERSION" \
	&& go install "github.com/foxboron/ssh-tpm-agent/cmd/...@v${VERSION}" \
	&& cp $GOPATH/bin/ssh-tpm-agent /usr/local/bin/

FROM mirror.gcr.io/alpine:3.20

COPY --from=build /usr/local/bin/ssh-tpm-agent /usr/local/bin/ssh-tpm-agent

VOLUME [ "/.ssh" ]
USER 65532:65532
ENTRYPOINT ["/usr/local/bin/ssh-tpm-agent", "-l", "/var/tmp/ssh-tpm-agent.sock"]
