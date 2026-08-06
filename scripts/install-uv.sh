#!/usr/bin/env bash
# Installs a pinned uv release straight from GitHub, checksum-verified — not the
# astral.sh/install.sh script, which resolves "latest" unless pinned via env var and
# isn't checksum-checked by default. Astral's static binary bootstraps its own Python
# interpreters, so it needs no compiler in-image.
# claudebox_info.json note: keep UV_VERSION in sync with docs/build.md's version table.
set -euo pipefail

UV_VERSION="0.11.32"

case "$(dpkg --print-architecture)" in
  amd64) uv_target="x86_64-unknown-linux-gnu" ;;
  arm64) uv_target="aarch64-unknown-linux-gnu" ;;
  *)
    echo "error: unsupported architecture $(dpkg --print-architecture)" >&2
    exit 1
    ;;
esac

archive="uv-${uv_target}.tar.gz"
base_url="https://github.com/astral-sh/uv/releases/download/${UV_VERSION}"

work_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir"' EXIT

curl -fsSL "${base_url}/${archive}" -o "${work_dir}/${archive}"
curl -fsSL "${base_url}/${archive}.sha256" -o "${work_dir}/${archive}.sha256"

(
  cd "$work_dir"
  sha256sum -c "${archive}.sha256"
)

tar -xzf "${work_dir}/${archive}" -C "$work_dir"
install -m 0755 "${work_dir}/uv-${uv_target}/uv" /usr/local/bin/uv
install -m 0755 "${work_dir}/uv-${uv_target}/uvx" /usr/local/bin/uvx
