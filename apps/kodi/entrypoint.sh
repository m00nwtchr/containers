#!/usr/bin/env sh

set -eu

XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
HOME="${HOME:-/data}"

if [ ! -d "${XDG_RUNTIME_DIR}" ] || [ ! -w "${XDG_RUNTIME_DIR}" ]; then
  printf 'XDG_RUNTIME_DIR is not writable: %s\n' "${XDG_RUNTIME_DIR}" >&2
  exit 1
fi

if [ ! -d "${HOME}" ] || [ ! -w "${HOME}" ]; then
  printf 'HOME is not writable: %s\n' "${HOME}" >&2
  exit 1
fi

export HOME
export XDG_RUNTIME_DIR

exec /usr/bin/kodi-wayland "$@"
