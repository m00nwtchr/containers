FROM mirror.gcr.io/alpine:3.20 AS build
ARG VERSION
WORKDIR /src

RUN apk add --no-cache \
  build-base \
  ca-certificates \
  curl \
  curl-dev \
  curl-static \
  expat-dev \
  expat-static \
  openssl-dev \
  openssl-libs-static \
  perl \
  zlib-dev \
  zlib-static

RUN test -n "$VERSION"

RUN curl -L "https://github.com/git/git/archive/refs/tags/v${VERSION}.tar.gz" \
  | tar -xz --strip-components=1

RUN make configure \
  && ./configure \
    --prefix=/usr \
    --without-tcltk

RUN make \
    CFLAGS="-O2 -static" \
    LDFLAGS="-static" \
    NO_GETTEXT=YesPlease \
    NO_ICONV=YesPlease \
    NO_PCRE2=YesPlease \
    NO_PERL=YesPlease \
    NO_TCLTK=YesPlease \
  && make install DESTDIR=/out \
  && strip /out/usr/bin/git

FROM mirror.gcr.io/distroless/static-debian12:nonroot

COPY --from=build /out/usr/bin/git /usr/bin/git

ENTRYPOINT ["/usr/bin/git"]
