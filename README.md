# claudebox

[![PR build, test, scan](https://github.com/tungbq/claudebox/actions/workflows/pr-build-test.yml/badge.svg)](https://github.com/tungbq/claudebox/actions/workflows/pr-build-test.yml)
[![Scheduled security scan](https://github.com/tungbq/claudebox/actions/workflows/scheduled-security-scan.yml/badge.svg)](https://github.com/tungbq/claudebox/actions/workflows/scheduled-security-scan.yml)
[![Scheduled version check](https://github.com/tungbq/claudebox/actions/workflows/scheduled-version-check.yml/badge.svg)](https://github.com/tungbq/claudebox/actions/workflows/scheduled-version-check.yml)

Minimal Ubuntu 24.04 container image with Claude Code and a lean dev toolset. Pull, run,
mount your code, start working.

**Built disposable.** No container is precious — `docker rm` it any time. The only state
that matters lives in one place, the `~/.cbox` volume: your `claude` login, git config,
`gh` auth. Rebuild the image whenever the pinned tool versions move; the environment
underneath is meant to be thrown away and remade, not nursed.

## Tool versions

<!-- versions:start -->
| Tool | Version |
|---|---|
| claude-code | 2.1.220 |
| node | 22.23.2 |
| npm | 12.0.1 |
| python | 3.12 |
| gh | 2.x |
| uv | 0.11.32 |
| yq | v4.53.3 |
<!-- versions:end -->

## What's in the image / what's deliberately not

Cut from the reference image: `build-essential`, `tmux`, `vim`, `fzf`, `git-delta`. No
compiler, so an npm or Python dependency that needs `node-gyp` or a source build without
a prebuilt wheel will fail to install — that's the intended tradeoff for a smaller image.

`python3`, `python3-venv`, and `uv` **are** included, so both `uvx`- and
`python -m`-launched MCP servers work alongside `npx`-launched ones — that's the question
people actually have, so it's worth saying explicitly rather than leaving it implied by
an unlabeled tool-versions table.

## Usage

Build once, then run — mount your code at `/workspace` and a named volume at
`/home/agent/.cbox` so your `claude` login (and git/gh config) survives `docker rm`.

### Linux / macOS / WSL2

```bash
docker build -t claudebox:dev .

docker run --rm -it \
  -v "$PWD":/workspace \
  -v claudebox-config:/home/agent/.cbox \
  claudebox:dev
```

### Windows (PowerShell, Docker Desktop + WSL2 backend)

```powershell
docker build -t claudebox:dev .

docker run --rm -it `
  -v "${PWD}:/workspace" `
  -v claudebox-config:/home/agent/.cbox `
  claudebox:dev
```

Either command drops you into `bash` inside the container — a minimal Ubuntu 24.04 box
with `git`, `gh`, `node`, `python3`/`uv`, `rg`, `fd`, `jq`/`yq`, and Claude Code already
installed. Run `claude` to log in (first time only — it persists in the
`claudebox-config` volume) and work like you would on a normal machine.

See [`docs/usage.md`](docs/usage.md) for the full run reference (SSH forwarding,
headless/CI mode, `HOST_UID`/`HOST_GID` overrides) and the `cbox` CLI.
[`docs/build.md`](docs/build.md) covers building it yourself — build args, multi-arch,
verification, and troubleshooting. Windows users: see
[`docs/windows.md`](docs/windows.md) for Git Bash/cmd.exe syntax, line-ending gotchas,
SSH forwarding, and where to keep your code for best I/O performance.

## Use it on a project you already have

Nothing to set up on the repo's side. `/workspace` is a direct bind mount, not a copy, so
you can point it at a real checkout and start working:

```bash
cd ~/code/your-existing-project

docker run --rm -it \
  -v "$PWD":/workspace \
  -v claudebox-config:/home/agent/.cbox \
  claudebox:dev
```

`agent` sees exactly what you see — `.git`, your existing branches, `node_modules`, build
output. Edits land on the host immediately rather than in a synced copy, so anything
`claude` writes or commits shows up in your host git tools the moment it happens.

The `claudebox-config` volume is tied to your login, not to a project: authenticate once,
then reuse it across every repo you mount, months apart, with no re-login. Point a
different volume at it when you want work and personal accounts kept apart.

Two things to know before aiming it at a real project. The image ships no compiler, so an
install step that needs `node-gyp` or a source build without a prebuilt wheel will fail
here even though it works on your host. And if the project directory is owned by another
user, the uid remap needs a look first. Both are covered in
[`docs/existing-project.md`](docs/existing-project.md).

## Security posture

This image runs an autonomous agent that executes untrusted content — a different threat
model from a typical dev tool. Design choices that follow from that:

- No passwordless `sudo` for the default `agent` user, ever. The escape hatch for
  host-side maintenance is `docker exec -u root -it claudebox bash`.
- SSH agent forwarding (`SSH_AUTH_SOCK`) is the documented path for git/SSH access.
  Mounting real private keys is opt-in (`-e CBOX_LINK_SSH=1`), off by default.
- The Docker socket is never part of a default run mode.
- `npm ci --ignore-scripts` runs tree-wide at install time; Claude Code's own
  load-bearing postinstall is individually allowlisted and run explicitly, rather than
  disabling the tree-wide protection to let it through.
- `~/.cbox` is the single config volume — everything that needs to persist across
  `docker rm` lives there, symlinked in from its normal path, migrated from any
  pre-existing real config with the original preserved as a `.pre-cbox-backup`.

Full detail in [`docs/codebase-summary.md`](docs/codebase-summary.md) and
[`SECURITY.md`](SECURITY.md).

## Status

Pre-release — there is no tagged release yet, and no version number to pin to.

Every verified `main` is published to `ghcr.io/tungbq/claudebox:edge`, alongside an
immutable `sha-<short>` tag for anyone who wants a fixed reference. `edge` moves with
`main` and deliberately isn't called `latest`, which would imply a stability guarantee
this project can't make yet. Building the image yourself per
[`docs/usage.md`](docs/usage.md) remains fully supported.

## License

[MIT](LICENSE)
