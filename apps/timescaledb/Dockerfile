ARG VERSION

FROM postgres:18-trixie AS build

RUN apt-get update && \
    apt-get upgrade -y && \
    apt-get install -y postgresql-server-dev-18 build-essential cmake curl && \
    rm -rf /var/lib/apt/lists

WORKDIR /tmp

RUN curl -sL https://github.com/timescale/timescaledb/archive/refs/tags/${VERSION}.tar.gz | tar xz && \
    ./timescaledb-*/bootstrap && \
    DESTDIR=../built make -C build install

RUN mkdir -p out/share/extension out/lib && \
    find built/usr/share -type f -print0 | xargs -0 mv -vt out/share/extension && \
    find built/usr/lib -type f -print0 | xargs -0 mv -vt out/lib

FROM scratch

COPY --from=build /tmp/out/ /