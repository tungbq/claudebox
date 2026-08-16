# Security Policy

## Supported Versions

This project is pre-release; see the README's Status section. The only published images
are `edge` (whatever the latest verified `main` is) and the per-commit `sha-<short>`
tags. Fixes land on `edge` by moving `main` forward — older `sha-` tags are immutable
and never patched in place, so pinning one means opting out of security updates.

There is no tagged release yet. Once one exists, only the most recent `latest` tag and
the most recent tagged release will receive security fixes. There is no long-term
support branch.

## Reporting a Vulnerability

Please **do not** open a public issue for a suspected vulnerability. Instead, use
GitHub's private vulnerability reporting (Security tab → "Report a vulnerability")
on this repository. Include:

- The image tag or commit you tested
- Steps to reproduce
- The impact you believe it has

Expect an initial response within a few days. This is a solo-maintained project, so
turnaround time depends on severity and maintainer availability.

## Threat Model, in Brief

This image runs an autonomous AI agent (Claude Code) that executes untrusted content
(prompts, fetched web pages, repository contents). That is a materially different
threat model from a typical developer tool, and the image is designed around it: no
passwordless sudo for the default user, SSH agent forwarding preferred over mounting
private keys, and the Docker socket is never part of a default run mode. See the
README's "Security posture" section for the summary and
[`docs/usage.md`](docs/usage.md) for day-to-day operation.

## Scanning

Every PR and push to `main` builds the image and runs it through Trivy, gated on
fixable HIGH/CRITICAL findings (`--ignore-unfixed`); results publish to this
repository's Security tab. The same gate runs before the `edge` image is pushed to
ghcr.io, and again before any tagged release — nothing reaches the registry without
passing it.

Findings we can't fix ourselves yet — because upstream hasn't shipped a patched
release — are documented with a dated justification and re-review expiry in
[`.trivyignore`](.trivyignore), not silently suppressed. Everything currently listed
there is a Go stdlib or bundled-dependency issue inside a third-party binary that has
no patched upstream build available.

One gap worth stating plainly: the weekly re-scan job targets the `:latest` tag, which
only a tagged release creates. Until then it has nothing to scan, so published `edge`
images are covered by the gate at publish time but not by an ongoing re-scan that would
catch CVEs disclosed afterwards.
