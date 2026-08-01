# Building the image

How to build `claudebox` locally, verify the result, and understand what CI does
differently. For running the image once built, see [`usage.md`](usage.md).

## Prerequisites

- Docker 23+ with BuildKit (the Dockerfile uses `# syntax=docker/dockerfile:1`)
- `jq` — required by `verify-versions.sh` / `smoke-test.sh`
- Optional: `buildx` + QEMU for cross-arch builds, `trivy` for local scanning,
  `bats` for the `cbox` CLI tests

On Windows, read [`windows.md`](windows.md) first — line endings will break the build if
your checkout predates the repo's `.gitattributes`.

Disk: the final image is ~1.1GB (measured; see `claudebox_info.json`'s `measured_size`).
Budget several GB including build cache.

## Quick build

```bash
docker build -t claudebox:dev .
```

That's the whole happy path. Everything below is for specific needs.

## Build arguments

| Arg | Default | Purpose |
|---|---|---|
| `USER_UID` | `1000` | uid of the in-image `agent` user |
| `USER_GID` | `1000` | gid of the in-image `agent` user |
| `BUILD_DATE` | `unknown` | RFC3339 timestamp, surfaces in `cbox info` and OCI labels |
| `REVISION` | `unknown` | git sha, surfaces in `cbox info` and OCI labels |

`USER_UID`/`USER_GID` are usually unnecessary — the entrypoint remaps `agent` to the
workspace owner at container start. Set them only if you want the image itself pinned
to your uid (e.g. shipping to a fleet of identical hosts, or debugging the remap
path). See [`usage.md`](usage.md#run) for the runtime alternative.

Build with full metadata the way CI does:

```bash
docker build \
  --build-arg BUILD_DATE="$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --build-arg REVISION="$(git rev-parse HEAD)" \
  -t claudebox:dev .
```

## Build context

`.dockerignore` keeps `.git`, `.github`, `docs/`, `plans/`, `tests/` and all `*.md` out
of the context — none of it is needed inside the image. If you add a new top-level
directory that the Dockerfile does not `COPY`, add it there too.

## Stage layout and caching

The Dockerfile has five stages, split so an upgrade to one tool doesn't invalidate the
others' layers:

| Stage | Contents |
|---|---|
| `base` | Ubuntu 24.04 + apt system tools + `gosu` |
| `node` | Node tarball, downloaded and checksum-verified in isolation |
| `yq` | mikefarah `yq` binary (not Ubuntu's unrelated apt package) |
| `claude-code` | throwaway stage: `npm ci` for `@anthropic-ai/claude-code` as an unprivileged user |
| `final` | `agent` user, copies from `node`/`yq`/`claude-code`, `cbox` CLI, entrypoint |

Consequences worth knowing when iterating:

- Bumping the Node or yq version rebuilds only that stage plus `final`, not the apt layer.
- Editing `cli/`, `entrypoint.sh` or `claudebox_info.json` only rebuilds the tail of
  `final` — those `COPY`s sit deliberately last.
- Editing anything under `scripts/install-*.sh` invalidates from that stage down.
- The `claude-code` stage's `npm ci` step keys off the committed
  `npm-lockfiles/claude-code/package-lock.json`, so it only reruns when the lockfile
  changes. It transplants into `final` as a single `COPY --chown=root:root` — not an
  install-in-place followed by a `chown -R` — because two full-tree metadata rewrites
  over a ~500MB payload each add a duplicate layer (measured: nearly doubled the image).

## Multi-arch

CI builds `linux/amd64` and `linux/arm64` on every PR, and the release job pushes a
combined manifest. To reproduce a foreign-arch build locally:

```bash
docker run --privileged --rm tonistiigi/binfmt --install all   # once per host
docker buildx build --platform linux/arm64 --load -t claudebox:arm64 .
```

`--load` accepts one platform at a time; building both at once requires `--push` to a
registry or `--output type=oci`. Emulated arm64 builds on an amd64 host are slower than
native — expect several times the native build time for the `npm ci` step in particular.

## Verifying a build

Run the same gates CI runs, in the same order:

```bash
# 1. Version pins actually hold inside the image
scripts/verify-versions.sh claudebox:dev

# 2. Every manifest tool runs, not just reports a version
scripts/smoke-test.sh claudebox:dev

# 3. cbox CLI and entrypoint behavior
IMAGE=claudebox:dev bats tests/test-cbox.bats

# 4. Vulnerability gate — fixable HIGH/CRITICAL blocks merge and release
trivy image --severity HIGH,CRITICAL --ignore-unfixed \
  --ignorefile .trivyignore claudebox:dev
```

`verify-versions.sh` only checks that each tool's version string matches the manifest;
`smoke-test.sh` additionally invokes each npm-installed binary's `--help`, catching a
CLI that resolves on PATH but is broken (missing shared lib, failed native extraction).
Run both — they fail on different things.

Shell lint, which CI runs as a separate job:

```bash
shellcheck --shell=sh cli/cbox cli/cmd/*.sh scripts/lib/common.sh
shellcheck entrypoint.sh scripts/bootstrap-config.sh scripts/install-*.sh \
  scripts/gen-lockfile.sh scripts/gen-version-table.sh \
  scripts/verify-versions.sh scripts/smoke-test.sh scripts/check-upstream-versions.sh
```

## Rebuilding after a version bump

`claudebox_info.json` is the source of truth for npm package pins and
version-verification expectations — it is **not** authoritative for every pinned
version. Four values live in two places: `node`, `npm`, `yq`, and `gosu` are each pinned
a second time as a constant inside their `scripts/install-*.sh` script (a header comment
in each script names the manifest entry to keep in sync). There is no generator that
closes this loop; a manifest-only edit changes nothing about what those four scripts
actually install. `claude-code` is the only value with a single source of truth (the
manifest), because the Dockerfile installs it from the committed lockfile, which is
itself generated from the manifest.

After bumping `claude-code`'s version in the manifest, regenerate the lockfile before
building:

```bash
scripts/gen-lockfile.sh
(cd npm-lockfiles/claude-code && npm install --package-lock-only)
scripts/gen-version-table.sh --inject README.md
docker build -t claudebox:dev . && scripts/verify-versions.sh claudebox:dev
```

Commit `package.json` together with its `package-lock.json`. The generated
`allowScripts` key is a security control, not incidental output — review it before
committing; see [CONTRIBUTING.md](../CONTRIBUTING.md#bumping-the-claude-code-version).

## What CI does

| Workflow | Trigger | Behavior |
|---|---|---|
| `pr-build-test.yml` | PR / push to `main` touching build inputs | shellcheck; build both arches; base image and Claude Code checks; Trivy → Security tab |
| `release.yml` | `v*` tag | builds and pushes a staging manifest to GHCR, gates it (verify/smoke/bats/Trivy on both arches), then promotes that exact digest to the release tags via `docker buildx imagetools create` — never a second build. `latest` only moves for non-prerelease tags. CycloneDX SBOM, GitHub release. |
| `scheduled-security-scan.yml` | cron | Trivy against the published `:latest` image |
| `scheduled-version-check.yml` | cron | compares the npm-pinned `claude-code` version to npm latest; opens a bump PR on drift that bumps the manifest only — the lockfile (and its `allowScripts` grant) is deliberately left for a human to regenerate and review |

CI uses GitHub Actions cache (`type=gha`, scoped per arch), so a local build starting
cold will be slower than a CI run.

### Registry

Images publish to **`ghcr.io/tungbq/claudebox`** only, using the workflow's built-in
`GITHUB_TOKEN` — no secrets need provisioning for this to work. Docker Hub is a planned
addition, gated behind a `DOCKERHUB_ENABLED` repository variable plus
`DOCKERHUB_USERNAME`/`DOCKERHUB_TOKEN` secrets; absent those, the Docker Hub steps in
`release.yml` are skipped cleanly and never fail a release.

Coverage note: `scheduled-version-check.yml` tracks exactly one of seven manifest
entries (`claude-code`, the only one with an `npm` key). `node`, `npm`, `uv`, and `yq`
carry exact pins tracked only in their install scripts; `gh` and `python` are
intentionally `.x`. A green run of that workflow means claude-code is current — it says
nothing about the other six.

### Rollback

If a published `latest` (or any tag) turns out to be bad:

```bash
# Point `latest` at a known-good previous digest without rebuilding.
docker buildx imagetools create \
  --tag ghcr.io/tungbq/claudebox:latest \
  ghcr.io/tungbq/claudebox@sha256:<known-good-digest>
```

Find `<known-good-digest>` from a prior release's `release.yml` run log (the "Assert
published digest matches the gated digest" step prints it), or via
`docker buildx imagetools inspect ghcr.io/tungbq/claudebox:vX.Y.Z`.

A **partial publish** (gate passed, but a later step in `publish` failed — e.g. the SBOM
or GitHub Release step) is not a corrupt image: the digest was already fully verified
and pushed by the time `publish` starts promoting tags. Re-run the failed `publish` job
from the Actions UI; it re-promotes the same already-gated digest, it does not rebuild.
"Push another tag" is not the right fix for either scenario — it triggers a brand new
gate-and-build cycle instead of recovering the one that already happened.

## Troubleshooting

- **`npm ci` fails with a lockfile/`package.json` mismatch** — the manifest was edited
  without regenerating. Run the bump sequence above.
- **An install script is blocked during `npm ci`** — npm 12+ requires an `allowScripts`
  entry keyed `<pkg>@<version>`. `gen-lockfile.sh` generates it; a hand-edited
  `package.json` will silently drop it after a version bump.
- **`verify-versions.sh` reports drift right after a clean build** — the pinned version
  no longer resolves to what upstream publishes under that tag, or an auto-updater ran
  inside the image. Both are real failures; do not paper over them by loosening the pin.
- **Trivy fails on something with no fix available** — it already runs with
  `--ignore-unfixed`, so a failure means a fix exists. Rebuild against current apt/npm
  state first; only add a `.trivyignore` entry with a rationale and a revisit date.
- **arm64 build is slow** — QEMU emulation of the `npm ci` step in particular is
  memory-hungry. Raise the Docker VM memory limit, or build natively on arm64 hardware.
- **Build context is unexpectedly large** — check whether a new top-level directory
  needs a `.dockerignore` entry.
