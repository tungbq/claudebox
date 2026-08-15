# claudebox

[![PR build, test, scan](https://github.com/tungbq/claudebox/actions/workflows/pr-build-test.yml/badge.svg)](https://github.com/tungbq/claudebox/actions/workflows/pr-build-test.yml)
[![Scheduled security scan](https://github.com/tungbq/claudebox/actions/workflows/scheduled-security-scan.yml/badge.svg)](https://github.com/tungbq/claudebox/actions/workflows/scheduled-security-scan.yml)
[![Scheduled version check](https://github.com/tungbq/claudebox/actions/workflows/scheduled-version-check.yml/badge.svg)](https://github.com/tungbq/claudebox/actions/workflows/scheduled-version-check.yml)

Minimal Ubuntu 24.04 container image with Claude Code and a lean dev toolset. Pull, run,
mount your code, start working.

**Sibling project:** [tungbq/aiagentkit](https://github.com/tungbq/aiagentkit) — same
architecture and release discipline, with several more AI coding agent CLIs installed
alongside Claude Code instead of just the one. Reach for that one if you want the fuller
agent lineup; reach for this one if Claude Code is all you run and you'd rather not carry
the rest.

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

Pre-release. No image has been published to `ghcr.io/tungbq/claudebox` yet — build it
yourself per [`docs/usage.md`](docs/usage.md) until a tagged release exists.

## License

[MIT](LICENSE)
