#!/usr/bin/env bash
# Installs a pinned gosu release from GitHub, checksum- and signature-verified. gosu is
# what the entrypoint uses to drop from root to `agent` after the UID/GID remap — su/sudo
# don't reap zombies or forward signals correctly as PID 1's replacement, which is the
# whole reason gosu exists. A substituted gosu that silently execs as uid 0 would make the
# entire non-root design a no-op while `gosu --version` still looks right, so the checksum
# alone (fetched from the same host that could be spoofed) is not enough — the sums file
# itself must be GPG-verified against a key fingerprint pinned here, not fetched live.
# claudebox_info.json note: keep GOSU_VERSION in sync with docs/build.md's version table.
set -euo pipefail

GOSU_VERSION="1.19"
# tianon's signing key, per https://github.com/tianon/gosu#installation and INSTALL.md.
GOSU_GPG_FINGERPRINT="B42F6819007F00F88E364FD4036A9C25BF357DD4"

case "$(dpkg --print-architecture)" in
  amd64) gosu_asset="gosu-amd64" ;;
  arm64) gosu_asset="gosu-arm64" ;;
  *)
    echo "error: unsupported architecture $(dpkg --print-architecture)" >&2
    exit 1
    ;;
esac

base_url="https://github.com/tianon/gosu/releases/download/${GOSU_VERSION}"

work_dir="$(mktemp -d)"
export GNUPGHOME="${work_dir}/gnupg"
mkdir -m 0700 "$GNUPGHOME"
trap 'gpgconf --kill all 2>/dev/null || true; rm -rf "$work_dir"' EXIT

curl -fsSL "${base_url}/${gosu_asset}" -o "${work_dir}/${gosu_asset}"
curl -fsSL "${base_url}/SHA256SUMS" -o "${work_dir}/SHA256SUMS"
curl -fsSL "${base_url}/SHA256SUMS.asc" -o "${work_dir}/SHA256SUMS.asc"

gpg --batch --keyserver hkps://keys.openpgp.org --recv-keys "$GOSU_GPG_FINGERPRINT"
gpg --batch --verify "${work_dir}/SHA256SUMS.asc" "${work_dir}/SHA256SUMS"

(
  cd "$work_dir"
  grep " ${gosu_asset}\$" SHA256SUMS | sha256sum -c -
)

install -m 0755 "${work_dir}/${gosu_asset}" /usr/local/bin/gosu
