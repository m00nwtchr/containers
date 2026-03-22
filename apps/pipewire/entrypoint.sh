#!/usr/bin/env sh

set -eu

XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/tmp/xdg-runtime-dir-$(id -u)}"

mkdir -p "${XDG_RUNTIME_DIR}"
chmod 700 "${XDG_RUNTIME_DIR}"

export XDG_RUNTIME_DIR

exec /usr/bin/pipewire "$@"
