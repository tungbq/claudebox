#!/bin/sh
# cbox info — image identity: version, base image, build date, revision, arch. Build
# date and revision come from env vars the Dockerfile mirrors from its LABEL block.
set -eu

script_dir="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"
if [ -f "$script_dir/common.sh" ]; then
  # shellcheck source=/dev/null
  . "$script_dir/common.sh"
else
  # shellcheck disable=SC1091
  . "$script_dir/../scripts/lib/common.sh"
fi

manifest="${CBOX_MANIFEST:-/usr/local/lib/cbox/claudebox_info.json}"
[ -f "$manifest" ] || die "manifest not found: $manifest"

name=$(jq -r '.name' "$manifest")
version=$(jq -r '.version' "$manifest")
base=$(jq -r '.base_image' "$manifest")

echo "$name $version"
echo "  base image   $base"
echo "  build date   ${CLAUDEBOX_BUILD_DATE:-unknown}"
echo "  revision     ${CLAUDEBOX_REVISION:-unknown}"
echo "  arch         $(uname -m)"
