#!/bin/sh
# Shared logging/error helpers for entrypoint.sh, bootstrap-config.sh, and the `cbox` CLI —
# kept in one place so all of them report problems in the same voice. Written in POSIX sh
# (no bashisms) since the cbox CLI itself must run under plain `/bin/sh`.

log_info() {
  printf '[cbox] %s\n' "$*"
}

log_warn() {
  printf '[cbox] warn: %s\n' "$*" >&2
}

log_error() {
  printf '[cbox] error: %s\n' "$*" >&2
}

die() {
  log_error "$*"
  exit 1
}

# Wraps jq against the baked-in manifest. Usage: manifest_get '.tools["claude-code"].version'
manifest_get() {
  jq -r "$1" "${CBOX_MANIFEST:-/usr/local/lib/cbox/claudebox_info.json}" 2>/dev/null
}

# Colour only when stdout is a real terminal — never inject escape codes into piped or
# redirected output (e.g. `cbox doctor --quiet` feeding a script, or entrypoint.sh's hint).
# Consumed by cli/cmd/doctor.sh, which shellcheck can't see from this file alone.
# shellcheck disable=SC2034
if [ -t 1 ]; then
  COLOR_GREEN='\033[32m'
  COLOR_YELLOW='\033[33m'
  COLOR_RED='\033[31m'
  COLOR_RESET='\033[0m'
else
  COLOR_GREEN=''
  COLOR_YELLOW=''
  COLOR_RED=''
  COLOR_RESET=''
fi
