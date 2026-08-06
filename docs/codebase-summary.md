# Codebase summary

What's in this repo and why, for anyone orienting themselves before making a change.
For day-to-day commands see [`usage.md`](usage.md) and [`build.md`](build.md).

## Layout

```
claudebox_info.json          version/tooling manifest — see "The manifest contract" below
Dockerfile                    five stages: base, node, yq, claude-code, final
entrypoint.sh                 root-context: uid/gid remap, then hands off to `agent`
scripts/
  install-*.sh                 one script per pinned tool, run at build time
  bootstrap-config.sh          agent-context: ~/.cbox symlink farm, run on every start
  gen-lockfile.sh               regenerates npm-lockfiles/claude-code/package.json
  gen-version-table.sh          renders the manifest as a Markdown table
  verify-versions.sh            CI/local gate: installed versions match the manifest
  smoke-test.sh                 CI/local gate: each binary actually runs, not just resolves
  check-upstream-versions.sh    compares the npm pin against latest; --patch for the bot
  lib/common.sh                 shared logging + manifest_get(), sourced by everything above
cli/
  cbox                          dispatcher: cbox <command> -> cmd/<command>.sh
  cmd/{doctor,versions,info}.sh  the three subcommands
npm-lockfiles/claude-code/     committed package.json + package-lock.json
tests/test-cbox.bats           exercises the built image, not source files
.github/workflows/             pr-build-test, release, two scheduled jobs
docs/                          this directory
```

## Image layout at runtime

- `/home/agent` — the `agent` user's home. `.agents/claude-code` (root-owned, read-only
  to agent) holds the installed npm package; everything else under `.agents` doesn't
  exist — there is exactly one tool.
- `/home/agent/.cbox` — the persistent config volume mount point. Empty/ephemeral unless
  the caller mounts a named volume there.
- `/workspace` — the bind-mount point for the user's code. `WORKDIR` for the whole
  container.
- `/usr/local/lib/cbox/` — everything `cbox` needs at runtime: the dispatcher, `cmd/`,
  `common.sh`, `bootstrap-config.sh`, and the baked-in read-only manifest copy.
  `/usr/local/bin/cbox` and `/usr/local/bin/claudebox` are symlinks into it.

## Request flow on `docker run`

1. `entrypoint.sh` runs as root: hard-resets `PATH`, validates any `HOST_UID`/`HOST_GID`,
   detects the target uid/gid from whichever of `/workspace` or `~/.cbox` is actually
   mounted, remaps `agent` via `usermod`/`groupmod` if needed (with a scoped, not
   recursive, `chown` — see the comment in `entrypoint.sh` for why), then drops to
   `agent` via `gosu` for everything downstream. `gosu` exists specifically because
   `su`/`sudo` don't forward signals or reap zombies correctly as PID 1's replacement.
2. `bootstrap-config.sh` runs as `agent` on every start: creates `~/.cbox` if needed,
   migrates any pre-existing real `~/.claude`, `~/.claude.json`, `~/.config/gh`,
   `~/.gitconfig` into it (copy → verify → swap, original preserved as
   `~/<name>.pre-cbox-backup`), symlinks each back to its normal path, re-enforces
   `~/.cbox` permissions, and writes this container's single-writer lock entry under
   `~/.cbox/.locks/<hostname>`.
3. The requested command (`claude`, `bash`, `cbox ...`) runs as `agent`, with a PATH that
   includes the npm-installed `claude` binary — passed explicitly per-invocation, never
   exported into the entrypoint's own environment, so root's command resolution stays
   hardened for the life of the container.
4. On shutdown, the trap removes only this container's own lock entry and forwards the
   signal to the running command before the entrypoint itself exits.

## The manifest contract

`claudebox_info.json` is the source of truth for **npm package pins and
version-verification expectations** — deliberately not claimed as authoritative for
*every* pinned version. Four values (`node`, `npm`, `yq`, `gosu`) are pinned a second
time as constants inside their respective `scripts/install-*.sh`, because the Dockerfile
installs those from upstream release artifacts, not from anything the manifest can drive
directly. Each install script's header comment names the manifest entry it must be kept
in sync with; there is no generator that closes this loop automatically. `claude-code` is
the one entry with a genuine single source of truth, because its install comes from a
lockfile generated *from* the manifest.

Every manifest entry's `version_cmd` has actually been run and proven to work — nothing
here is an invented pin. `jq`, `ripgrep`, and `fd` are installed but not manifest-tracked:
they're stock distro packages with no independent pinning mechanism, so CI asserts their
presence with `which` instead of a version check.

## CI workflows

- **`pr-build-test.yml`** — shellcheck (every shell file in the repo) plus a build+test
  matrix over both architectures: base image assertions, `verify-versions.sh`,
  `smoke-test.sh`, the bats suite, and a Trivy scan gated on fixable HIGH/CRITICAL.
- **`release.yml`** — on a `v*` tag: builds and pushes a staging manifest to GHCR, gates
  that exact digest (same checks as the PR workflow), then promotes it to the real
  release tags via `docker buildx imagetools create` — a re-tag, never a rebuild, so the
  bits that get scanned are provably the bits that ship.
- **`scheduled-security-scan.yml`** — weekly Trivy scan of the published `:latest` image;
  opens an issue (not a PR) on new findings.
- **`scheduled-version-check.yml`** — weekly comparison of the pinned `claude-code`
  version against npm latest; opens a PR that bumps the manifest only, deliberately
  leaving the lockfile (and its `allowScripts` grant) for a human to regenerate and
  review as a follow-up commit.

## What's deliberately not here

Ported from the sibling multi-agent project (see the README) with everything that
existed only to serve multiple installed agent CLIs removed: the `login` subcommand and
its per-agent instruction tables, the lockfile split that separated tools needing
install scripts from those that didn't, a PATH wrapper one other agent needed to force
an auto-update flag on every invocation, `build-essential`/`tmux`/`vim`/`fzf`/
`git-delta`, and a build-arg-emitting script whose output had zero functional consumers
even in the reference repo.
