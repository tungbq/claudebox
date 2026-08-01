# Contributing

## Ground rules

- **`claudebox_info.json` is the source of truth for npm package pins and
  version-verification expectations.** It is not authoritative for every pinned
  version — `node`, `npm`, `gosu`, and `yq` are also pinned as constants inside their
  install scripts under `scripts/install-*.sh`; each of those scripts names the
  manifest entry it must stay in sync with. See `docs/build.md` for the full list.
- Keep individual files under ~200 lines; split by concern rather than growing a file.
- Shell scripts should pass `shellcheck` and set `-euo pipefail` (POSIX `/bin/sh`
  scripts under `cli/` are the exception — they can't use `pipefail`).
- Conventional commits (`feat:`, `fix:`, `docs:`, `refactor:`, `test:`, `chore:`), no
  AI-authorship references in commit messages.

## Bumping the claude-code version

1. Update the `tools["claude-code"].version` entry in `claudebox_info.json`.
2. Regenerate the lockfile: `scripts/gen-lockfile.sh`, then
   `(cd npm-lockfiles/claude-code && npm install --package-lock-only)`.
3. Run `scripts/verify-versions.sh <image>` against a locally built image to confirm
   the new version actually reports correctly before opening a PR.
4. `scripts/gen-version-table.sh --inject README.md` to refresh the version table.

A scheduled workflow (`scheduled-version-check.yml`) also compares the npm-pinned
claude-code version against its npm latest weekly and opens a bump PR when they
drift — that PR still requires a human to add the `allowScripts` key by hand; see
`docs/build.md`.

## Local checks before opening a PR

```bash
jq -e . claudebox_info.json
shellcheck scripts/*.sh
scripts/gen-version-table.sh
```

Changed anything the image ships? Build it and run the same gates CI runs —
[`docs/build.md`](docs/build.md) has the full sequence.

## Reporting issues

Use the issue templates — they ask for the information needed to reproduce a problem
(image tag, host OS, Docker version) up front.
