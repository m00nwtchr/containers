#!/usr/bin/env sh

set -eu

: "${XDG_RUNTIME_DIR:?XDG_RUNTIME_DIR not set}"

check_writable_dir() {
  path="$1"
  name="$2"
  if [ ! -d "${path}" ] || [ ! -w "${path}" ]; then
    printf '%s is not writable: %s\n' "${name}" "${path}" >&2
    exit 1
  fi
}

check_writable_dir "${XDG_RUNTIME_DIR}" "XDG_RUNTIME_DIR"

exec /usr/bin/pipewire "$@"
