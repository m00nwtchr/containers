FROM mirror.gcr.io/golang:alpine AS build
ARG VERSION

RUN test -n "$VERSION" \
	&& go install "github.com/foxboron/ssh-tpm-agent/cmd/...@v${VERSION}" \
	&& cp $GOPATH/bin/ssh-tpm-agent /usr/local/bin/ \
	&& cp $GOPATH/bin/ssh-tpm-keygen /usr/local/bin/

FROM mirror.gcr.io/alpine:3.20

COPY --from=build /usr/local/bin/ssh-tpm-agent /usr/local/bin/ssh-tpm-agent
COPY --from=build /usr/local/bin/ssh-tpm-keygen /usr/local/bin/ssh-tpm-keygen

VOLUME [ "/.ssh" ]
USER 1000:1000
ENTRYPOINT ["/usr/local/bin/ssh-tpm-agent", "-l", "/var/tmp/ssh-tpm-agent.sock"]
