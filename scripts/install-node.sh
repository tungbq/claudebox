#!/usr/bin/env bash
# Downloads the official Node.js Linux tarball and verifies it against nodejs.org's
# published SHASUMS256.txt before extracting. Deliberately not the NodeSource apt repo,
# which tracks its own release cadence and drifts from the version pinned here.
# claudebox_info.json note: keep NODE_VERSION / NPM_VERSION in sync with docs/build.md's
# version table — this script is the second of the two places both live.
set -euo pipefail

# npm bundled with this Node build carries stale transitive deps (brace-expansion,
# picomatch, sigstore, tar) with known HIGH/CRITICAL CVEs — Node's release cadence lags
# npm's own. Pin an explicit, newer npm and self-update to it below; npm's registry
# install path verifies package integrity itself, so no separate checksum step is needed
# the way gosu/yq (raw GitHub binary downloads) require one. npm must stay >= 12, or the
# claude-code lockfile's allowScripts gate goes inert.
NODE_VERSION="22.23.2"
NPM_VERSION="12.0.1"

case "$(dpkg --print-architecture)" in
  amd64) node_arch="x64" ;;
  arm64) node_arch="arm64" ;;
  *)
    echo "error: unsupported architecture $(dpkg --print-architecture)" >&2
    exit 1
    ;;
esac

tarball="node-v${NODE_VERSION}-linux-${node_arch}.tar.xz"
base_url="https://nodejs.org/dist/v${NODE_VERSION}"

work_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir"' EXIT

curl -fsSL "${base_url}/${tarball}" -o "${work_dir}/${tarball}"
curl -fsSL "${base_url}/SHASUMS256.txt" -o "${work_dir}/SHASUMS256.txt"

(
  cd "$work_dir"
  grep " ${tarball}\$" SHASUMS256.txt | sha256sum -c -
)

tar -xJf "${work_dir}/${tarball}" -C /usr/local --strip-components=1 --no-same-owner

/usr/local/bin/npm install -g "npm@${NPM_VERSION}"
