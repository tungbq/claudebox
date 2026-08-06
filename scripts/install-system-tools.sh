#!/usr/bin/env bash
# Single apt layer for the base image: system packages plus the GitHub CLI's official
# repo. Kept out of the Dockerfile so the package list stays readable; still runs as one
# RUN so it produces exactly one image layer.
set -euo pipefail

apt-get update
apt-get install -y --no-install-recommends \
  ca-certificates \
  curl \
  gnupg

# gh ships from its own apt repo with a pinned, GPG-verified keyring — not `curl | bash`.
install -d -m 0755 /usr/share/keyrings
curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
  -o /usr/share/keyrings/githubcli-archive-keyring.gpg
chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
  > /etc/apt/sources.list.d/github-cli.list

apt-get update
apt-get install -y --no-install-recommends \
  git \
  gh \
  ripgrep \
  fd-find \
  jq \
  wget \
  openssh-client \
  less \
  python3 \
  python3-venv

# Debian/Ubuntu package the binary as `fdfind` to avoid a name clash with an unrelated tool.
ln -s "$(command -v fdfind)" /usr/local/bin/fd

rm -rf /var/lib/apt/lists/*
