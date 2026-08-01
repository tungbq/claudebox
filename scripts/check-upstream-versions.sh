#!/usr/bin/env bash
# Compares each npm-based tool's pinned version in claudebox_info.json against the
# latest published on npm. For claudebox that is exactly one of seven tracked tools
# (claude-code) — node, npm, uv, and yq carry exact pins tracked only in their install
# scripts, and gh/python are intentionally ".x" — see docs/build.md for the full split.
# Prints a drift summary to stdout and, with --patch, writes a manifest with drifted
# versions bumped so a caller (the scheduled-version-check workflow) can diff it
# straight into a PR. Exits 0 whether or not drift was found — drift is data for the
# caller to act on, not a failure of this script.
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  echo "Usage: $0 [manifest-path] [--patch <output-path>]" >&2
  exit 1
}

manifest="${script_dir}/../claudebox_info.json"
patch_out=""

while [ $# -gt 0 ]; do
  case "$1" in
    --patch)
      patch_out="${2:-}"
      [ -n "$patch_out" ] || usage
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

if ! command -v npm >/dev/null 2>&1; then
  echo "error: npm is required" >&2
  exit 1
fi

if [ ! -f "$manifest" ]; then
  echo "error: manifest not found: $manifest" >&2
  exit 1
fi

working="$manifest"
if [ -n "$patch_out" ]; then
  working="$patch_out"
  cp "$manifest" "$working"
fi

drift=0
summary=""

while IFS=$'\t' read -r key pkg pinned; do
  latest="$(npm view "$pkg" version 2>/dev/null || true)"
  if [ -z "$latest" ]; then
    printf 'warn %-12s could not resolve latest version for %s\n' "$key" "$pkg" >&2
    continue
  fi

  if [ "$latest" = "$pinned" ]; then
    printf 'ok   %-12s %s (pinned) == %s (latest)\n' "$key" "$pinned" "$latest"
    continue
  fi

  drift=1
  printf 'DRIFT %-11s %s (pinned) -> %s (latest)\n' "$key" "$pinned" "$latest"
  summary="${summary}- **${key}**: ${pinned} -> ${latest} — https://www.npmjs.com/package/${pkg}/v/${latest}\n"

  if [ -n "$patch_out" ]; then
    tmp="$(mktemp)"
    jq --arg key "$key" --arg version "$latest" \
      '.tools[$key].version = $version' "$working" > "$tmp" && mv "$tmp" "$working"
  fi
done < <(jq -r '
  .tools
  | to_entries[]
  | select(.value.npm)
  | [.key, .value.npm, .value.version]
  | @tsv
' "$manifest")

if [ "$drift" -eq 0 ]; then
  echo "no drift: all pinned npm versions match latest"
else
  echo
  echo "## Version drift detected"
  echo
  printf '%b' "$summary"
fi

exit 0
