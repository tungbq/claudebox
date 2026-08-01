#!/bin/sh
# cbox doctor — health check: Claude Code version/auth, config symlink integrity,
# workspace/config-volume mount state, network reachability, and janitorial items
# (unbounded Claude Code MCP backups, stale single-writer lock entries). Auth is a
# presence check on the auth_marker file, not a validity check — a stale marker still
# reads "authenticated". A fresh, not-yet-logged-in container is informational, never a
# health-check failure — run `claude` to log in. Exit 0 healthy, 1 couldn't even run the
# checks, 2 degraded.
set -eu

script_dir="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"
if [ -f "$script_dir/common.sh" ]; then
  # shellcheck source=/dev/null
  . "$script_dir/common.sh"
else
  # shellcheck disable=SC1091
  . "$script_dir/../scripts/lib/common.sh"
fi

quiet=0
for arg in "$@"; do
  [ "$arg" = "--quiet" ] && quiet=1
done

manifest="${CBOX_MANIFEST:-/usr/local/lib/cbox/claudebox_info.json}"
command -v jq >/dev/null 2>&1 || die "jq not found"
[ -f "$manifest" ] || die "manifest not found: $manifest"

attention=0
img_name=$(jq -r '.name' "$manifest")
img_version=$(jq -r '.version' "$manifest")
img_base=$(jq -r '.base_image' "$manifest")

if [ "$quiet" -eq 0 ]; then
  printf '%s %s  (%s, %s, built %s)\n\n' \
    "$img_name" "$img_version" "$img_base" "$(uname -m)" "${CLAUDEBOX_BUILD_DATE:-unknown}"
  echo "Claude Code"
fi

for tool in $(jq -r '.tools | to_entries[] | select(.value.npm) | .key' "$manifest"); do
  bin=$(jq -r ".tools[\"$tool\"].bin" "$manifest")
  pinned=$(jq -r ".tools[\"$tool\"].version" "$manifest")
  marker=$(jq -r ".tools[\"$tool\"].auth_marker // empty" "$manifest")
  store=$(jq -r ".tools[\"$tool\"].store // empty" "$manifest")

  # Resolved against the manifest's `store` field, never the manifest key — the key is
  # "claude-code" but bootstrap-config.sh creates the store directory "claude".
  if [ -n "$marker" ] && [ -n "$store" ] && [ -f "$HOME/.cbox/$store/$marker" ]; then
    status="${COLOR_GREEN}authenticated${COLOR_RESET}"
  elif [ -n "$marker" ]; then
    # Not authenticated is informational, not a fault — every fresh container and every
    # CI run legitimately starts this way. Reserve `attention`/degraded for things that
    # are actually wrong (uid mismatch, unwritable volume, broken symlinks, below).
    status="${COLOR_YELLOW}not authenticated${COLOR_RESET}   -> run 'claude' to log in"
  else
    status="unknown (auth_marker not yet determined)"
  fi

  [ "$quiet" -eq 1 ] || printf '  %-9s %-9s %b\n' "$bin" "$pinned" "$status"
done

symlink_total=0
symlink_ok=0
for path in "$HOME/.claude" "$HOME/.claude.json" "$HOME/.config/gh" "$HOME/.gitconfig"; do
  symlink_total=$((symlink_total + 1))
  if [ -L "$path" ] && [ -e "$path" ]; then
    symlink_ok=$((symlink_ok + 1))
  fi
done
[ "$symlink_ok" -eq "$symlink_total" ] || attention=1

workspace_status="not mounted"
if [ -d /workspace ] && [ "$(stat -c %d /)" != "$(stat -c %d /workspace)" ]; then
  ws_uid=$(stat -c %u /workspace)
  my_uid=$(id -u)
  if [ "$ws_uid" = "$my_uid" ]; then
    workspace_status="mounted, uid $my_uid matches host"
  elif [ -w /workspace ]; then
    # Docker Desktop's file sharing presents Windows/macOS bind mounts as root:root 0777.
    # That ownership is synthesized by the VM, not the host's: the agent can write, and
    # host-side files keep the desktop user's ownership. Writability is what actually
    # matters here, so a uid difference alone is not a fault worth flagging.
    workspace_status="mounted, writable (ownership managed by host)"
  else
    workspace_status="${COLOR_RED}mounted, not writable (uid $ws_uid vs $my_uid)${COLOR_RESET}"
    attention=1
  fi
fi

cbox_status="not mounted (ephemeral — nothing persists across containers)"
if [ -d "$HOME/.cbox" ] && [ "$(stat -c %d /)" != "$(stat -c %d "$HOME/.cbox")" ]; then
  if [ -w "$HOME/.cbox" ]; then
    cbox_status="mounted, writable"
  else
    cbox_status="${COLOR_RED}mounted, NOT writable${COLOR_RESET}"
    attention=1
  fi
fi

net_status="unreachable (or offline — expected for air-gapped use)"
if command -v curl >/dev/null 2>&1 \
  && curl -fsS --max-time 2 https://registry.npmjs.org/ >/dev/null 2>&1; then
  net_status="reachable"
fi

if [ "$quiet" -eq 0 ]; then
  echo
  echo "Environment"
  printf '  config volume  %-20s %b\n' "$HOME/.cbox" "$cbox_status"
  printf '  workspace      %-20s %b\n' "/workspace" "$workspace_status"
  printf '  symlinks       %s/%s intact\n' "$symlink_ok" "$symlink_total"
  printf '  network        %s\n' "$net_status"
fi

backup_count=0
if [ -d "$HOME/.claude/backups" ]; then
  backup_count=$(find "$HOME/.claude/backups" -maxdepth 1 -name '.claude.json.backup.*' 2>/dev/null | wc -l)
fi

# Other containers' single-writer lock entries. Doctor has no docker socket (by design —
# see the security posture), so it cannot ask docker whether a listed container is still
# running; it can only show what's on disk and let the human judge, with the exact
# command to clear an entry once they've confirmed it's stale.
this_id="$(cat /etc/hostname 2>/dev/null || hostname 2>/dev/null || echo unknown)"
locks_dir="$HOME/.cbox/.locks"
other_locks=""
if [ -d "$locks_dir" ]; then
  for lock in "$locks_dir"/*; do
    [ -e "$lock" ] || continue
    [ "$(basename "$lock")" = "$this_id" ] && continue
    other_locks="${other_locks}${lock}
"
  done
fi

if [ "$quiet" -eq 0 ] && { [ "$backup_count" -gt 0 ] || [ -n "$other_locks" ]; }; then
  echo
  echo "Janitorial"
  [ "$backup_count" -eq 0 ] || printf '  %s unbounded Claude Code MCP backups in ~/.claude/backups\n' "$backup_count"
  if [ -n "$other_locks" ]; then
    echo "$other_locks" | while IFS= read -r lock; do
      [ -n "$lock" ] || continue
      printf '  lock held by %s since %s — if that container is no longer running: rm %s\n' \
        "$(basename "$lock")" "$(cat "$lock" 2>/dev/null || echo unknown)" "$lock"
    done
  fi
fi

if [ "$quiet" -eq 1 ]; then
  if [ "$attention" -eq 1 ]; then
    echo "degraded"
  else
    echo "healthy"
  fi
else
  echo
  if [ "$attention" -eq 1 ]; then
    echo "Some checks need attention."
  else
    echo "All checks healthy."
  fi
fi

if [ "$attention" -eq 1 ]; then
  exit 2
fi
exit 0
