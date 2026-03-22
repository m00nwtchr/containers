#!/usr/bin/env sh

set -eu

SEATD_SOCKET="${SEATD_SOCK:-/run/seatd.sock}"
WESTON_BACKEND="${WESTON_BACKEND:-drm-backend.so}"
WESTON_SHELL="${WESTON_SHELL:-kiosk-shell.so}"
XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/tmp/xdg-runtime-dir-$(id -u)}"

if [ ! -S "${SEATD_SOCKET}" ]; then
  printf 'seatd socket not found at %s\n' "${SEATD_SOCKET}" >&2
  printf 'mount host seatd socket and set SEATD_SOCK if needed\n' >&2
  exit 1
fi

mkdir -p "${XDG_RUNTIME_DIR}"
chmod 700 "${XDG_RUNTIME_DIR}"

export LIBSEAT_BACKEND="seatd"
export SEATD_SOCK="${SEATD_SOCKET}"
export XDG_RUNTIME_DIR

exec /usr/bin/weston --backend="${WESTON_BACKEND}" --shell="${WESTON_SHELL}" "$@"
