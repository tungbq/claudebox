# Usage

No published image yet ([status](../README.md#status)) — build locally from a checkout.

Commands below use POSIX shell syntax. On Windows, see [`windows.md`](windows.md) for the
PowerShell/Git Bash equivalents and the WSL2 setup.

## Build

```bash
docker build -t claudebox:dev .
```

Runs as uid/gid 1000 by default. On Linux, if your host user isn't 1000, either pass
`--build-arg USER_UID=$(id -u) --build-arg USER_GID=$(id -g)` at build time, or leave the
default and let the entrypoint remap at runtime (see below) — the runtime remap is enough
for most cases and the build-arg is only needed if you want the image itself pinned to
your uid.

For build args, multi-arch builds, layer caching, verification steps and build
troubleshooting, see [`build.md`](build.md).

## Run

Two mounts matter: `/workspace` for your code, and a config volume for `~/.cbox` so your
`claude` login survives `docker rm`.

```bash
docker run --rm -it \
  -v "$PWD":/workspace \
  -v claudebox-config:/home/agent/.cbox \
  claudebox:dev
```

This drops you into `bash` inside the container (the default `CMD`). Run `claude`
directly, or pass it as the command:

```bash
docker run --rm -it \
  -v "$PWD":/workspace \
  -v claudebox-config:/home/agent/.cbox \
  claudebox:dev claude
```

The entrypoint remaps the container's `agent` user to match `/workspace`'s owner (or the
config volume's, if `/workspace` isn't mounted) on every start, so files the agent creates
are host-owned, not root-owned. Override with `-e HOST_UID=<uid> -e HOST_GID=<gid>` if the
auto-detected owner is wrong. A workspace owned by root is refused — the container stays at
uid 1000 rather than silently running as root.

### With host git / SSH

Agent forwarding is the default path — no keys enter the container:

```bash
docker run --rm -it \
  -v "$PWD":/workspace \
  -v claudebox-config:/home/agent/.cbox \
  -v "$SSH_AUTH_SOCK":/ssh-agent -e SSH_AUTH_SOCK=/ssh-agent \
  claudebox:dev
```

Mounting real keys into `~/.ssh` is opt-in, not the default, because a container running
untrusted agent content is exactly the wrong place to hand out unforwarded private keys:

```bash
docker run --rm -it \
  -v "$PWD":/workspace \
  -v claudebox-config:/home/agent/.cbox \
  -v "$HOME/.ssh":/home/agent/.ssh:ro -e CBOX_LINK_SSH=1 \
  claudebox:dev
```

### Headless / CI

No TTY, API key via env, no interactive login:

```bash
docker run --rm \
  -e ANTHROPIC_API_KEY \
  -v "$PWD":/workspace \
  claudebox:dev claude -p "some prompt"
```

## Logging in

Run `claude` — it prints a URL, approve on any device, paste the code back. Headless:
`export ANTHROPIC_API_KEY=<key>`. There is no `cbox login`; `cbox` only reports on and
configures the environment, it never proxies Claude Code.

Logins persist in the config volume across `docker rm` — mount the same volume next time
and skip the login step entirely.

## `cbox` CLI reference

`cbox` (alias `claudebox`) reports on and configures the environment; it never proxies
Claude Code invocations.

| Command | Purpose |
|---|---|
| `cbox doctor` | health check: version, auth status, config symlinks, workspace/volume mount state, network reachability |
| `cbox doctor --quiet` | same check, prints only `healthy` or `degraded`, for scripting |
| `cbox versions` | installed vs. pinned versions, flags drift |
| `cbox info` | image version, base, build date, arch |
| `cbox help` | usage summary |

## Troubleshooting

- **`cbox doctor` reports a uid mismatch on `/workspace`** — the entrypoint couldn't
  remap to the workspace owner. Pass `-e HOST_UID=<uid> -e HOST_GID=<gid>` explicitly.
- **`usermod failed` / "uid already exists in image"** — the target host uid collides
  with a system account baked into the image. Re-run with a different `HOST_UID`, or
  rebuild with `--build-arg USER_UID=<uid>`.
- **`groupmod failed` / "gid already exists in image"** — the target host gid collides
  with a system group baked into the image. This is common on macOS (primary group
  `staff` is often gid 20, colliding with the image's `dialout`) and on Arch/Fedora/NixOS
  (primary group `users` is often gid 100). Re-run with a different `-e HOST_GID=<gid>`,
  or rebuild with `--build-arg USER_GID=<gid>`.
- **Config volume warns another container already holds it** — two containers sharing one
  `~/.cbox` volume can each refresh the same OAuth token and invalidate the other's copy.
  `cbox doctor` lists each other lock entry by hostname and age; if that container is no
  longer running, clear its stale lock with the `rm` command doctor prints. Safe to
  ignore if the other container is still running and you intend that.
- **A previous real `~/.claude` (or `~/.gitconfig`, `~/.config/gh`) got migrated** —
  bootstrap copies it into the config volume and leaves the original as
  `~/<name>.pre-cbox-backup` rather than deleting it. Remove the backup yourself once
  you've confirmed the migration is good.
