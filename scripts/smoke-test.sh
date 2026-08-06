#!/usr/bin/env bash
# Runs each manifest tool's version_cmd inside a built image and a `--help` invocation
# for the npm-installed ones. Complements verify-versions.sh (which only checks the
# version string matches): a binary can print *something* on stderr and still be
# broken — e.g. a missing shared lib, or a native extraction that silently failed — so
# this checks the command's exit status, not just whether it produced output. --help is
# limited to npm-key tools: stock distro binaries (gh, node's own smoke via version_cmd,
# etc.) can't have a broken *native extraction* the way an npm postinstall can, and each
# probe costs a container start under QEMU. --help failures are reported but don't fail
# the run: not every CLI supports the flag the same way.
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  echo "Usage: $0 <image-tag> [manifest-path]" >&2
  exit 1
}

[ $# -ge 1 ] || usage

image="$1"
manifest="${2:-${script_dir}/../claudebox_info.json}"

if ! command -v jq >/dev/null 2>&1; then
  echo "error: jq is required" >&2
  exit 1
fi

if ! command -v docker >/dev/null 2>&1; then
  echo "error: docker is required" >&2
  exit 1
fi

if [ ! -f "$manifest" ]; then
  echo "error: manifest not found: $manifest" >&2
  exit 1
fi

fail=0

while IFS=$'\t' read -r name bin version_cmd has_npm; do
  status=0
  version_out="$(docker run --rm "$image" sh -c "$version_cmd" 2>&1)" || status=$?
  if [ "$status" -eq 0 ]; then
    printf 'ok   %-12s version_cmd -> %s\n' "$name" "$version_out"
  else
    printf 'FAIL %-12s version_cmd exited %d: %s\n' "$name" "$status" "$version_out"
    fail=1
  fi

  [ "$has_npm" = "true" ] || continue

  help_status=0
  help_out="$(docker run --rm "$image" sh -c "$bin --help" 2>&1)" || help_status=$?
  if [ "$help_status" -eq 0 ] && [ -n "$help_out" ]; then
    printf 'ok   %-12s --help produced output (%d bytes)\n' "$name" "${#help_out}"
  else
    printf 'warn %-12s --help exited %d\n' "$name" "$help_status"
  fi
done < <(jq -r '
  .tools
  | to_entries[]
  | select(.value.version_cmd and .value.bin)
  | [.key, .value.bin, .value.version_cmd, ((.value.npm != null) | tostring)]
  | @tsv
' "$manifest")

if [ "$fail" -ne 0 ]; then
  echo "error: one or more tools failed their smoke test" >&2
  exit 1
fi

echo "all tools smoke-tested against $image"
