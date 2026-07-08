# syntax=docker/dockerfile:1.7
#
# Stage 1: build a static musl-linked Rust binary on Alpine.
# Stage 2: copy the binary onto a `scratch` image (no shell, no libc,
# no package manager, just the binary). This keeps the final image
# at the smallest possible size.
#
# Build args (injected by the build farm's prepare-matrices.py):
#   VERSION   - the image version (matches Cargo.toml)
#   REVISION  - git revision sha
#   CHANNEL   - release channel name (e.g. "stable")
# TARGETARCH is injected by buildx automatically.

ARG RUST_VERSION=1.83

# ---- build stage ---------------------------------------------------------
FROM rust:${RUST_VERSION}-alpine AS build
RUN apk add --no-cache musl-dev
WORKDIR /build

# Pre-build a stub main to cache the dependency graph. The deps layer
# (Cargo.toml + Cargo.lock) only re-builds when one of them changes,
# so source-only edits skip this step.
COPY Cargo.toml Cargo.lock ./
RUN mkdir -p src && \
    echo 'fn main() {}' > src/main.rs && \
    cargo build --release --target x86_64-unknown-linux-musl && \
    rm -rf src target

# Now build the real source. The cargo offline cache from the step
# above is invalidated automatically when src/ changes.
COPY src ./src
RUN cargo build --release --target x86_64-unknown-linux-musl && \
    strip target/x86_64-unknown-linux-musl/release/scdaemon-shim

# ---- runtime stage: scratch + the binary -------------------------------
# scratch has nothing, so the binary must be fully self-contained.
# The Rust build above produces a static musl binary (no dynamic
# dependencies) so it runs unmodified on scratch.
FROM scratch
COPY --from=build /build/target/x86_64-unknown-linux-musl/release/scdaemon-shim \
     /usr/local/bin/scdaemon-shim

# Build-farm args are accepted (and ignored) so the same Dockerfile
# works whether built by the build farm or directly with `docker build`.
ARG VERSION=0.0.0
ARG REVISION=unknown
ARG CHANNEL=stable

# gpg-agent launches the program named by its `scdaemon-program`
# config option via exec(); an ENTRYPOINT is the natural choice.
ENTRYPOINT ["/usr/local/bin/scdaemon-shim"]
