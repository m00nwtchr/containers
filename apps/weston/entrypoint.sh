#!/usr/bin/env sh

set -eu

SEATD_SOCKET="${SEATD_SOCK:-/run/seatd.sock}"
WESTON_BACKEND="${WESTON_BACKEND:-drm-backend.so}"
WESTON_SHELL="${WESTON_SHELL:-kiosk-shell.so}"
XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"

if [ ! -S "${SEATD_SOCKET}" ]; then
  printf 'seatd socket not found at %s\n' "${SEATD_SOCKET}" >&2
  printf 'mount host seatd socket and set SEATD_SOCK if needed\n' >&2
  exit 1
fi

if [ ! -d "${XDG_RUNTIME_DIR}" ] || [ ! -w "${XDG_RUNTIME_DIR}" ]; then
  printf 'XDG_RUNTIME_DIR is not writable: %s\n' "${XDG_RUNTIME_DIR}" >&2
  exit 1
fi

export LIBSEAT_BACKEND="seatd"
export SEATD_SOCK="${SEATD_SOCKET}"
export XDG_RUNTIME_DIR

exec /usr/bin/weston --backend="${WESTON_BACKEND}" --shell="${WESTON_SHELL}" "$@"
