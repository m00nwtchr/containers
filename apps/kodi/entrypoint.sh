#!/usr/bin/env sh

set -eu

XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/tmp/xdg-runtime-dir-$(id -u)}"
HOME="${HOME:-/data}"

mkdir -p "${XDG_RUNTIME_DIR}" "${HOME}"
chmod 700 "${XDG_RUNTIME_DIR}"

export HOME
export XDG_RUNTIME_DIR

exec /usr/bin/kodi-wayland "$@"
