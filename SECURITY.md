# Security Policy

## Supported Versions

No image is published yet — this project is pre-release; see the README's Status
section. Once images are published, only the most recent `latest` tag and the most
recent tagged release will receive security fixes. There is no long-term support branch.

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
repository's Security tab. Findings we can't fix ourselves yet — because upstream
hasn't shipped a patched release — are documented with a dated justification and
re-review expiry in [`.trivyignore`](.trivyignore), not silently suppressed. The same
gate runs again before any tagged release, plus a weekly re-scan of the published
`:latest` image once one exists (see the README's Status section — none has been
published yet, so there's nothing for that weekly job to scan today).
