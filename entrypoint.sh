#!/usr/bin/env bash
# Container entrypoint. Runs as root: remaps `agent`'s uid/gid to match the mounted
# /workspace owner — or ~/.cbox's, if /workspace isn't mounted — so files it creates
# aren't host-root-owned. Then runs ~/.cbox bootstrap as `agent`, then hands off to the
# requested command as `agent`.
#
# The final step is a background-and-wait, not a bare `exec gosu agent "$@"`, so the
# EXIT/TERM/INT trap can clear this container's ~/.cbox/.locks/<hostname> entry (the
# single-writer marker bootstrap-config.sh writes) and forward the shutdown signal to the
# real command before this script exits.
set -euo pipefail

# Hard-reset PATH before anything else runs. `docker run -e PATH=...` can override the
# image's ENV PATH from outside, and every command below (rm, mountpoint, stat, getent,
# usermod, groupmod, chown, gosu) is called by bare name as root. Without this, an
# agent-written /home/agent/.npm-global/bin/rm would execute as root from the shutdown
# trap the moment both ~/.cbox and /workspace are mounted — no restart needed. This stays
# the script's own $PATH for its entire lifetime, including the cleanup() trap below —
# it is never widened back out for root's own command resolution.
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export PATH

# Everything actually run AS agent (bootstrap, doctor, the requested command) still needs
# claude-code's bin directory on PATH — that's not a root-resolution risk, since agent
# controlling its own PATH isn't a privilege escalation. Matches the image's Dockerfile
# ENV PATH ordering (agent-writable dirs last). Passed explicitly per `gosu` invocation
# via `env PATH=...`, never exported into this script's own environment.
AGENT_PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/home/agent/.npm-global/bin:/home/agent/.agents/claude-code/node_modules/.bin

# shellcheck disable=SC1091 # only exists inside the built image, not this repo checkout
source /usr/local/lib/cbox/common.sh

# Uid/gid configuration is `-e HOST_UID` / `-e HOST_GID` only — no config-file override is
# read here. Parsing a file from an agent-writable volume as root would be a
# root-escalation surface for no documented benefit.
#
# Normalize any provided value to a canonical base-10 integer now: `$((10#$v))` forces
# decimal interpretation so a value like "089" (invalid octal) can't crash the script with
# a bash arithmetic error, and "00" canonicalizes to "0" so later zero-checks are exact.
# Reject anything that isn't plain digits outright — a non-numeric HOST_UID is a user typo,
# not something to silently coerce.
validate_and_normalize_id() {
  var_name="$1"
  value="${!var_name:-}"
  [ -z "$value" ] && return 0
  case "$value" in
    ''|*[!0-9]*)
      die "$var_name must be a non-negative integer, got: '$value'"
      ;;
  esac
  if [ "${#value}" -gt 10 ]; then
    die "$var_name is too long to be a valid id: '$value'"
  fi
  normalized="$((10#$value))"
  if [ "$normalized" -gt 4294967295 ]; then
    die "$var_name exceeds the maximum valid id (4294967295): $value"
  fi
  printf -v "$var_name" '%s' "$normalized"
}
validate_and_normalize_id HOST_UID
validate_and_normalize_id HOST_GID

# /workspace and ~/.cbox both exist in the image (baked owner uid 1000, see Dockerfile),
# so a plain `stat` on either always succeeds whether or not a host dir is bind-mounted
# there — `stat || stat` never falls through. `mountpoint -q` is the actual bind-mount
# test; only trust the owner uid of a mount that's really there.
if mountpoint -q /workspace; then
  owner_src=/workspace
elif mountpoint -q /home/agent/.cbox; then
  owner_src=/home/agent/.cbox
else
  owner_src=""
fi

if [ -n "$owner_src" ]; then
  TARGET_UID="${HOST_UID:-$(stat -c %u "$owner_src")}"
  TARGET_GID="${HOST_GID:-$(stat -c %g "$owner_src")}"
else
  TARGET_UID="${HOST_UID:-1000}"
  TARGET_GID="${HOST_GID:-1000}"
fi

# Both mounts unmounted, or mounted from a root-owned path, all yield 0. Remapping the
# agent to uid 0 would silently defeat the non-root design — refuse it and fall back to
# 1000, checked arithmetically so "00" can't slip past a string `= "0"` compare.
if [ "$TARGET_UID" -eq 0 ]; then
  # Docker Desktop's file sharing presents Windows/macOS bind mounts as root:root 0777.
  # That is synthesized ownership, not a root-owned host directory — the agent can still
  # write, and files land host-owned by the desktop user. Warning on it trains users to
  # ignore the warning, so only a mount that is root-owned *and* not world-writable (a
  # genuine Linux-host misconfiguration) is worth reporting.
  world_writable=no
  if [ -n "$owner_src" ]; then
    case "$(stat -c %a "$owner_src")" in
      *7) world_writable=yes ;;
    esac
  fi
  [ "$world_writable" = "yes" ] || log_warn "workspace owner is root; keeping agent at uid 1000"
  TARGET_UID=1000
fi
if [ "$TARGET_GID" -eq 0 ]; then
  log_warn "target gid resolved to 0 (root); keeping agent at gid 1000"
  TARGET_GID=1000
fi

# A host uid/gid may already belong to a system account in the image (e.g. 100 = _apt on
# some distros, or the host's primary group colliding with an image system group like
# dialout/20 or users/100). usermod/groupmod would fail; die loudly with a remedy rather
# than exec'ing with an undefined user state.
if [ "$TARGET_UID" != "$(id -u agent)" ]; then
  if getent passwd "$TARGET_UID" >/dev/null; then
    die "uid $TARGET_UID already exists in image ($(getent passwd "$TARGET_UID" | cut -d: -f1)); re-run with -e HOST_UID=<free-uid>, or rebuild with --build-arg USER_UID"
  fi
  if getent group "$TARGET_GID" >/dev/null; then
    die "gid $TARGET_GID already exists in image ($(getent group "$TARGET_GID" | cut -d: -f1)); re-run with -e HOST_GID=<free-gid>, or rebuild with --build-arg USER_GID"
  fi
  usermod -u "$TARGET_UID" agent || die "usermod failed"
  groupmod -g "$TARGET_GID" agent || die "groupmod failed"
  # Not `chown -R /home/agent`: /home/agent/.agents/claude-code holds hardlinked files
  # from npm's install cache, and a recursive chown over them forces an overlayfs copy-up
  # of each. `usermod -u` itself already walks the whole home tree re-owning every file
  # that still belongs to agent's old uid — measured at ~550MB and multiple seconds on
  # this payload alone, and no usermod flag disables that walk. The real fix lives in the
  # Dockerfile: /home/agent/.agents is root-owned at build time specifically so it never
  # matches agent's old uid and usermod skips it entirely. The exclusion here is
  # defense-in-depth on top of that, not the primary fix — do not widen this to
  # `-R /home/agent` without re-checking the Dockerfile's ownership first.
  chown "$TARGET_UID:$TARGET_GID" /home/agent
  # A bind-mounted top-level entry (e.g. `-e CBOX_LINK_SSH=1 -v ~/.ssh:/home/agent/.ssh:ro`)
  # must be skipped, not just filtered like .agents above: chown() on a read-only mount
  # fails with EROFS even when the target uid already matches — it's a real syscall, not a
  # no-op skip, and there is no ownership to fix from inside the container anyway since the
  # mount's ownership is governed entirely by the host side. /home/agent/.cbox is the one
  # mount that legitimately needs re-owning here (a freshly created named volume starts
  # root-owned); it gets that from the dedicated, targeted chown right below instead.
  for entry in /home/agent/.[!.]* /home/agent/*; do
    [ -e "$entry" ] || continue
    case "$(basename "$entry")" in
      .agents) continue ;;
    esac
    mountpoint -q "$entry" && continue
    chown "$TARGET_UID:$TARGET_GID" "$entry"
  done
fi

# A freshly created named volume is always root-owned by Docker itself, regardless of
# whether the agent uid above needed to change — the branch only fires on a uid
# mismatch, so it misses this case whenever the host uid equals the image's default
# uid 1000 (the common case, e.g. WSL2's default user). Fix the mount root directly;
# bootstrap-config.sh (running as agent next) owns everything it creates underneath it.
if mountpoint -q /home/agent/.cbox \
  && [ "$(stat -c %u /home/agent/.cbox)" != "$TARGET_UID" ]; then
  chown "$TARGET_UID:$TARGET_GID" /home/agent/.cbox
fi

env PATH="$AGENT_PATH" gosu agent /usr/local/lib/cbox/bootstrap-config.sh

# Interactive-only, silent when healthy — `cbox doctor` itself is one command away and
# this entrypoint shouldn't duplicate its full report on every start. Inert until the
# `/usr/local/bin/cbox` symlink exists; `|| true` makes that harmless either way.
if [ -t 0 ] && [ -t 1 ]; then
  doctor_status="$(env PATH="$AGENT_PATH" gosu agent /usr/local/bin/cbox doctor --quiet 2>/dev/null || true)"
  if [ "$doctor_status" = "degraded" ]; then
    log_warn "cbox doctor reports issues — run 'cbox doctor' for details"
  fi
fi

this_id="$(cat /etc/hostname 2>/dev/null || hostname 2>/dev/null || echo unknown)"

# shellcheck disable=SC2317,SC2329 # invoked via `trap`, not a direct call
cleanup() {
  # Remove only this container's own lock entry — never the shared .locks directory —
  # so one container exiting can't erase a still-running peer's marker and silence the
  # single-writer warning for whoever starts next.
  rm -f "/home/agent/.cbox/.locks/${this_id}" 2>/dev/null || true
  if [ -n "${child_pid:-}" ] && kill -0 "$child_pid" 2>/dev/null; then
    kill -TERM "$child_pid" 2>/dev/null || true
    wait "$child_pid" 2>/dev/null || true
  fi
}
trap cleanup TERM INT EXIT

env PATH="$AGENT_PATH" gosu agent "$@" &
child_pid=$!
wait "$child_pid"
exit_code=$?
exit "$exit_code"
