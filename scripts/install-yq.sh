#!/usr/bin/env bash
# Installs the Go-based mikefarah/yq (the `yq eval` tool most people mean by "yq" today),
# not Ubuntu's apt "yq" package — that is a different, older jq-wrapper with unrelated
# syntax. Verifies against yq's own multi-algorithm checksums file: the release ships no
# plain sha256sum-compatible file, so the SHA-256 column position is taken from the
# release's own checksums_hashes_order (field 19: filename + 18 preceding hash columns).
# claudebox_info.json note: keep YQ_VERSION in sync with docs/build.md's version table.
set -euo pipefail

YQ_VERSION="v4.53.3"

case "$(dpkg --print-architecture)" in
  amd64) yq_asset="yq_linux_amd64" ;;
  arm64) yq_asset="yq_linux_arm64" ;;
  *)
    echo "error: unsupported architecture $(dpkg --print-architecture)" >&2
    exit 1
    ;;
esac

base_url="https://github.com/mikefarah/yq/releases/download/${YQ_VERSION}"

work_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir"' EXIT

curl -fsSL "${base_url}/${yq_asset}" -o "${work_dir}/${yq_asset}"
curl -fsSL "${base_url}/checksums" -o "${work_dir}/checksums"
curl -fsSL "${base_url}/checksums_hashes_order" -o "${work_dir}/checksums_hashes_order"

(
  cd "$work_dir"
  sha256_field="$(grep -m1 -n "SHA-256" checksums_hashes_order | cut -f1 -d:)"
  sha256_field=$((sha256_field + 1))
  # checksums lists "<filename> <hash1> <hash2> ..."; sha256sum -c wants "<hash>  <filename>"
  grep "${yq_asset}[[:space:]]" checksums \
    | sed 's/  /\t/g' \
    | cut -f1,"${sha256_field}" \
    | awk -F'\t' '{print $2 "  " $1}' \
    | sha256sum -c -
)

install -m 0755 "${work_dir}/${yq_asset}" /usr/local/bin/yq
