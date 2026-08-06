#!/bin/sh
# cbox versions — installed vs pinned versions per claudebox_info.json. Exits 1 if
# anything drifted from what was pinned at build time, 0 if everything matches.
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

drift=0
printf '%-14s %-12s %-30s %s\n' "TOOL" "PINNED" "INSTALLED" "STATUS"

for tool in $(jq -r '.tools | keys[]' "$manifest"); do
  pinned=$(jq -r ".tools[\"$tool\"].version" "$manifest")
  bin=$(jq -r ".tools[\"$tool\"].bin // empty" "$manifest")
  version_cmd=$(jq -r ".tools[\"$tool\"].version_cmd // empty" "$manifest")
  [ -n "$bin" ] || continue

  if ! command -v "$bin" >/dev/null 2>&1; then
    printf '%-14s %-12s %-30s %s\n' "$tool" "$pinned" "-" "MISSING"
    drift=1
    continue
  fi

  actual="$($version_cmd 2>&1 | head -1 || true)"

  case "$pinned" in
    *.x)
      # A trailing ".x" (e.g. "2.x") means intentionally unpinned — match the major
      # version as a number boundary, same convention as scripts/verify-versions.sh.
      major="${pinned%.x}"
      if printf '%s' "$actual" | grep -qE "(^|[^0-9])${major}\.[0-9]"; then
        status="ok"
      else
        status="DRIFT"
        drift=1
      fi
      ;;
    *)
      if printf '%s' "$actual" | grep -qF -- "$pinned"; then
        status="ok"
      else
        status="DRIFT"
        drift=1
      fi
      ;;
  esac

  printf '%-14s %-12s %-30s %s\n' "$tool" "$pinned" "$actual" "$status"
done

if [ "$drift" -eq 1 ]; then
  exit 1
fi
exit 0
