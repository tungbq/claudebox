## What changed

<!-- One or two sentences on what this PR does and why. -->

## Checklist

- [ ] `claudebox_info.json` updated if any tool version changed (and nowhere else,
      unless the tool is one of the four with a second pin in an install script —
      see `docs/build.md`)
- [ ] `jq -e . claudebox_info.json` passes
- [ ] `shellcheck scripts/*.sh` (and `cli/**/*.sh`, `entrypoint.sh` if touched) is clean
- [ ] Ran the relevant scripts locally (`verify-versions.sh`, `smoke-test.sh`,
      `gen-version-table.sh`) if this touches version handling
- [ ] Docs updated if user-facing behavior changed
- [ ] Linked issue, if any

## Related issue

Closes #
