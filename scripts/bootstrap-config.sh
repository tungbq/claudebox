#!/usr/bin/env bash
# Idempotent ~/.cbox bootstrap. Runs as `agent` (invoked by entrypoint.sh after the
# UID/GID remap) on every container start. Creates the ~/.cbox skeleton, migrates any
# pre-existing real config dirs into it (copy -> verify -> swap, never move -> link, so a
# container killed mid-migration leaves the original untouched), symlinks each config path
# into ~/.cbox, re-enforces permissions, and warns if another container already holds this
# config volume.
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# In the repo this file lives in scripts/ next to lib/common.sh, but the Dockerfile
# flattens both into /usr/local/lib/cbox/ — check both so this also runs straight from a
# repo checkout (e.g. for local testing) without a build.
if [ -f "${script_dir}/common.sh" ]; then
  # shellcheck source=/dev/null
  source "${script_dir}/common.sh"
else
  # shellcheck disable=SC1091
  source "${script_dir}/lib/common.sh"
fi

CBOX_HOME="$HOME/.cbox"

mkdir -p "$CBOX_HOME"
chmod 0700 "$CBOX_HOME"

# Copy -> verify -> swap a real directory into $CBOX_HOME/<name>, then symlink $target at
# it. Any failure before the final rename leaves $target completely untouched. The
# pre-cbox-backup from the last step is never deleted by this script — only the user (or
# `cbox doctor`) removes it, once they've confirmed the migration is good.
link_dir() {
  local target="$1" name="$2"
  local store="$CBOX_HOME/$name"

  if [ -L "$target" ]; then
    return 0
  fi

  mkdir -p "$store"

  if [ -e "$target" ]; then
    local incoming="$CBOX_HOME/${name}.incoming"
    local is_mount=no
    mountpoint -q "$target" && is_mount=yes

    trap 'rm -rf "$incoming"' RETURN
    rm -rf "$incoming"
    cp -a "$target" "$incoming"

    # `{ find ... || true; }` around each find: GNU find tries to chdir back to its
    # starting directory when it's done (a defensive measure against symlink races) and
    # errors loudly if that directory — here, always /workspace, since WORKDIR never
    # changes for the life of the container — isn't accessible to the current uid. That
    # cosmetic failure would otherwise fail the whole pipeline under `pipefail`, even
    # though the count `wc -l` already captured is correct; find's own exit status
    # carries no information the count comparison below doesn't already provide.
    local src_count src_size dst_count dst_size
    src_count="$({ find "$target" || true; } | wc -l)"
    src_size="$(du -sb "$target" | cut -f1)"
    dst_count="$({ find "$incoming" || true; } | wc -l)"
    dst_size="$(du -sb "$incoming" | cut -f1)"
    if [ "$src_count" != "$dst_count" ] || [ "$src_size" != "$dst_size" ]; then
      die "migration verify failed for $name: copy mismatch (files $src_count vs $dst_count, bytes $src_size vs $dst_size) — original left untouched at $target"
    fi

    rm -rf "$store"
    mv "$incoming" "$store"
    trap - RETURN

    # A bind-mount point (e.g. `-v $HOME/.ssh:/home/agent/.ssh:ro`) can never be `mv`'d —
    # that's EBUSY, `mv` doesn't fall back to copy, and `set -e` would abort the whole
    # bootstrap, leaving the container permanently unable to start (the mount point is
    # still a non-symlink on every subsequent attempt too). Leave the mount in place;
    # $target keeps resolving into the mounted source, while $store holds the synced copy.
    if [ "$is_mount" = "yes" ]; then
      log_warn "synced bind-mounted $name config into $store as a persisted backup; $target stays the live mount and is not replaced with a symlink"
      return 0
    fi

    local backup
    backup="$HOME/$(basename "$name").pre-cbox-backup"
    mv "$target" "$backup"
    log_warn "migrated existing $name config into $store; original preserved at $backup"
  fi

  ln -s "$store" "$target"
}

# Same copy -> verify -> swap discipline as link_dir, for single files that live outside
# a tool's own config directory (Claude Code's ~/.claude.json). $3 is the content to seed
# the store with the first time it's ever created — defaults to empty. Claude Code parses
# ~/.claude.json as JSON on every launch, so a truly empty file is corrupt to it before the
# agent has ever run `claude` once; callers for JSON-backed targets must pass '{}'.
#
# $target itself never persists across containers — only $store, under $CBOX_HOME, lives
# on the mounted volume. So on every container after the first, $target is freshly absent
# again even though $store already holds real content from a prior run. Seeding must key
# off whether *$store* is new, never off whether $target exists: gating on $target would
# truncate real persisted content (an OAuth token, a gitconfig) back to the default on
# every single restart, silently discarding it. `[ -e "$target" ]` only fires for a real,
# non-symlinked file already sitting at $target — the pre-$CBOX_HOME migration case.
link_file() {
  local target="$1" name="$2" default_content="${3:-}"
  local store="$CBOX_HOME/$name"

  if [ -L "$target" ]; then
    return 0
  fi

  mkdir -p "$(dirname "$store")"

  if [ -e "$target" ]; then
    local backup
    backup="$HOME/$(basename "$name").pre-cbox-backup"
    cp -a "$target" "$store"
    if ! cmp -s "$target" "$store"; then
      die "migration verify failed for $name: copy mismatch — original left untouched at $target"
    fi
    mv "$target" "$backup"
    log_warn "migrated existing $name into $store; original preserved at $backup"
  elif [ ! -e "$store" ]; then
    printf '%s' "$default_content" > "$store"
  fi

  ln -s "$store" "$target"
}

link_dir "$HOME/.claude" claude
link_file "$HOME/.claude.json" claude.json '{}'

# Self-heal for config volumes created by a claudebox build predating the '{}' default
# above: those seeded the store as a truly empty file, which Claude Code treats as
# corrupt JSON on every launch. link_file() only seeds a fresh store — once the symlink
# exists it returns early every subsequent start — so an already-broken volume never
# self-corrects without this. Only touch it if still empty; never overwrite real content.
if [ -L "$HOME/.claude.json" ] && [ ! -s "$CBOX_HOME/claude.json" ]; then
  printf '{}' > "$CBOX_HOME/claude.json"
  log_warn "healed empty ~/.claude.json in $CBOX_HOME (was invalid JSON from an older claudebox bootstrap)"
fi

mkdir -p "$HOME/.config"
link_dir "$HOME/.config/gh" gh

mkdir -p "$CBOX_HOME/git"
link_file "$HOME/.gitconfig" git/gitconfig

# SSH is opt-in — mounting private keys into a container that runs untrusted content is
# a real exposure, so this only runs when the user has explicitly asked for it; agent
# forwarding via SSH_AUTH_SOCK is the documented default instead.
if [ "${CBOX_LINK_SSH:-0}" = "1" ]; then
  link_dir "$HOME/.ssh" ssh
  chmod 0700 "$CBOX_HOME/ssh"
  find "$CBOX_HOME/ssh" -type f -exec chmod 0600 {} + 2>/dev/null || true
fi

# Re-enforced every start, not just on first bootstrap.
chmod 0700 "$CBOX_HOME"
find "$CBOX_HOME" -maxdepth 2 -type f -exec chmod 0600 {} + 2>/dev/null || true

# ~/.claude.json.lock deliberately is NOT linked into ~/.cbox anywhere above — it stays on
# the container's own filesystem. A lock carried across containers on a shared volume is
# exactly the concurrent-access corruption scenario the section below describes.

# Single-writer marker: one file per container under $CBOX_HOME/.locks/<hostname>, not one
# shared file. A shared file that any container can overwrite and any container can delete
# fails closed only by accident — B overwriting A's slot then exiting would silently erase
# A's marker too, leaving C with no warning at all while A and C both refresh the same
# OAuth token. Per-container files can't step on each other: warn if any *other* file is
# already present, but only ever touch this container's own.
locks_dir="$CBOX_HOME/.locks"
mkdir -p "$locks_dir"
this_id="$(cat /etc/hostname 2>/dev/null || hostname 2>/dev/null || echo unknown)"
this_lock="$locks_dir/$this_id"

# `|| true`: GNU find's chdir-back-when-done can fail against an inaccessible cwd (see
# the comment on the same pattern in link_dir above) — cosmetic here too, since only the
# listing on stdout matters.
other_locks="$(find "$locks_dir" -maxdepth 1 -type f ! -name "$this_id" 2>/dev/null || true)"
if [ -n "$other_locks" ]; then
  log_warn "$CBOX_HOME is already marked in use by: $(echo "$other_locks" | xargs -n1 basename | tr '\n' ' ')— if any of those containers are still running, concurrent use can rotate OAuth tokens and log them out unexpectedly. If none are running (e.g. after 'docker kill'), these are stale; 'cbox doctor' can identify and clear them."
fi
date -u +%Y-%m-%dT%H:%M:%SZ > "$this_lock"
