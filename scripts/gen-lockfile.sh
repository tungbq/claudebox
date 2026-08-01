#!/usr/bin/env bash
# Regenerates npm-lockfiles/claude-code/package.json from claudebox_info.json. claude-code's
# postinstall wires up its native binary from optionalDependencies and is load-bearing, so
# it cannot install under --ignore-scripts — the Dockerfile runs `npm ci --ignore-scripts`
# tree-wide anyway (transitive-dependency protection) and then allowlists this one package
# via `npm rebuild`, which npm >= 12 gates on the `allowScripts` map generated below.
#
# After running this, regenerate the matching package-lock.json:
#   (cd npm-lockfiles/claude-code && npm install --package-lock-only)
# and commit both the package.json and package-lock.json changes together.
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
manifest="${1:-${script_dir}/../claudebox_info.json}"
out_dir="${script_dir}/../npm-lockfiles/claude-code"

if ! command -v jq >/dev/null 2>&1; then
  echo "error: jq is required" >&2
  exit 1
fi

if [ ! -f "$manifest" ]; then
  echo "error: manifest not found: $manifest" >&2
  exit 1
fi

mkdir -p "$out_dir"

jq '
  .tools["claude-code"] as $t
  | {
    name: "claudebox-claude-code-lockfile",
    private: true,
    description: "Pinned, integrity-locked install set for claudebox — see scripts/gen-lockfile.sh",
    dependencies: { ($t.npm): $t.version },
    allowScripts: { ($t.npm + "@" + $t.version): true }
  }
' "$manifest" > "${out_dir}/package.json"

echo "wrote ${out_dir}/package.json"
