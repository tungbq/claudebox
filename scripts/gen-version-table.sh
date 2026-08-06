#!/usr/bin/env bash
# Generates a Markdown version table from claudebox_info.json. With no --inject
# target, prints the table to stdout. With --inject <file>, replaces the content
# between `<!-- versions:start -->` and `<!-- versions:end -->` markers in place,
# so README/docs tables can never drift from the manifest.
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  echo "Usage: $0 [manifest-path] [--inject <target-file>]" >&2
  exit 1
}

manifest="${script_dir}/../claudebox_info.json"
inject_target=""

while [ $# -gt 0 ]; do
  case "$1" in
    --inject)
      inject_target="${2:-}"
      [ -n "$inject_target" ] || usage
      shift 2
      ;;
    -h|--help)
      usage
      ;;
    *)
      manifest="$1"
      shift
      ;;
  esac
done

if ! command -v jq >/dev/null 2>&1; then
  echo "error: jq is required" >&2
  exit 1
fi

if [ ! -f "$manifest" ]; then
  echo "error: manifest not found: $manifest" >&2
  exit 1
fi

table="$(
  {
    echo "| Tool | Version |"
    echo "|---|---|"
    jq -r '.tools | to_entries[] | "| " + .key + " | " + .value.version + " |"' "$manifest"
  }
)"

if [ -z "$inject_target" ]; then
  printf '%s\n' "$table"
  exit 0
fi

if [ ! -f "$inject_target" ]; then
  echo "error: inject target not found: $inject_target" >&2
  exit 1
fi

if ! grep -q '<!-- versions:start -->' "$inject_target" || ! grep -q '<!-- versions:end -->' "$inject_target"; then
  echo "error: $inject_target is missing versions:start/versions:end markers" >&2
  exit 1
fi

awk -v table="$table" '
  /<!-- versions:start -->/ {
    print
    print table
    in_block = 1
    next
  }
  /<!-- versions:end -->/ {
    in_block = 0
    print
    next
  }
  in_block == 1 { next }
  { print }
' "$inject_target" > "${inject_target}.tmp" && mv "${inject_target}.tmp" "$inject_target"

echo "updated version table in $inject_target"
