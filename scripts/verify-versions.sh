#!/usr/bin/env bash
# Runs each tool's version_cmd inside a built image and asserts the output contains
# the version pinned in claudebox_info.json. This is the gate that stops silent
# upstream drift (or a broken auto-updater) from shipping as a "pinned" release.
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

if ! docker info >/dev/null 2>&1; then
  echo "error: docker is on PATH but not usable (daemon unreachable or not integrated with this shell)" >&2
  exit 1
fi

if [ ! -f "$manifest" ]; then
  echo "error: manifest not found: $manifest" >&2
  exit 1
fi

fail=0

while IFS=$'\t' read -r name expected cmd; do
  actual="$(docker run --rm "$image" sh -c "$cmd" 2>&1 || true)"

  # A trailing ".x" (e.g. "2.x") means "intentionally unpinned, any patch is fine" —
  # match the major version as a number boundary instead of a literal substring.
  if [[ "$expected" == *.x ]]; then
    major="${expected%.x}"
    matched=$(printf '%s' "$actual" | grep -qE -- "(^|[^0-9])${major}\.[0-9]" && echo 1 || echo 0)
  else
    matched=$(printf '%s' "$actual" | grep -qF -- "$expected" && echo 1 || echo 0)
  fi

  if [ "$matched" -eq 1 ]; then
    printf 'ok   %-14s expected=%-10s actual=%s\n' "$name" "$expected" "$actual"
  else
    printf 'FAIL %-14s expected=%-10s actual=%s\n' "$name" "$expected" "$actual"
    fail=1
  fi
done < <(jq -r '
  .tools
  | to_entries[]
  | select(.value.version_cmd)
  | [.key, .value.version, .value.version_cmd]
  | @tsv
' "$manifest")

if [ "$fail" -ne 0 ]; then
  echo "error: one or more tools reported an unexpected version" >&2
  exit 1
fi

echo "all versions verified against $manifest"
