# syntax=docker/dockerfile:1

# Base: Ubuntu 24.04 + system packages + dev tooling. No Claude Code here — that layer
# must be independently buildable and cacheable, and stays root-only until it appends.
FROM ubuntu:26.04 AS base
ENV DEBIAN_FRONTEND=noninteractive
COPY scripts/install-system-tools.sh /tmp/install-system-tools.sh
RUN chmod +x /tmp/install-system-tools.sh \
 && /tmp/install-system-tools.sh \
 && rm /tmp/install-system-tools.sh

# gosu: what the entrypoint uses to drop from root to `agent` after the UID/GID remap —
# su/sudo don't forward signals or reap zombies correctly as PID 1's replacement.
COPY scripts/install-gosu.sh /tmp/install-gosu.sh
RUN chmod +x /tmp/install-gosu.sh \
 && /tmp/install-gosu.sh \
 && rm /tmp/install-gosu.sh

# Node: downloaded and checksum-verified in its own throwaway stage, independent of the
# apt layer above, so a Node version bump doesn't invalidate the system-tools cache.
FROM ubuntu:26.04 AS node
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl xz-utils \
 && rm -rf /var/lib/apt/lists/*
COPY scripts/install-node.sh /tmp/install-node.sh
RUN chmod +x /tmp/install-node.sh \
 && /tmp/install-node.sh \
 && rm /tmp/install-node.sh

# yq: same pattern — mikefarah/yq (the `yq eval` tool), not Ubuntu's unrelated apt package.
FROM ubuntu:26.04 AS yq
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl \
 && rm -rf /var/lib/apt/lists/*
COPY scripts/install-yq.sh /tmp/install-yq.sh
RUN chmod +x /tmp/install-yq.sh \
 && /tmp/install-yq.sh \
 && rm /tmp/install-yq.sh

# Claude Code: installed in its own throwaway stage, as an unprivileged user, with install
# scripts disabled tree-wide (protects against a compromised transitive dependency's
# install-time code) — claude-code's own load-bearing postinstall (wires its native
# binary) is allowlisted and run explicitly via `npm rebuild`, never blanket
# `--ignore-scripts` off. Kept out of `final` entirely: transplanting the finished
# ~500MB payload with a single `COPY --chown` below costs one layer, where installing
# in place and then re-chowning it costs two — each a full copy of the tree, since
# chown touches every file's metadata and neither Docker layers nor overlayfs diff
# that as anything less than the whole file.
FROM node AS claude-code
RUN useradd -m installer
COPY npm-lockfiles/claude-code/package.json npm-lockfiles/claude-code/package-lock.json \
     /home/installer/claude-code/
RUN chown -R installer:installer /home/installer/claude-code
USER installer
RUN cd /home/installer/claude-code \
 && npm ci --omit=dev --no-fund --no-audit --ignore-scripts \
 && npm rebuild @anthropic-ai/claude-code --foreground-scripts \
 && rm -rf node_modules/@anthropic-ai/claude-code-linux-x64-musl \
           node_modules/@anthropic-ai/claude-code-linux-arm64-musl \
 && npm cache clean --force

FROM base AS final

# Ubuntu 24.04 ships a stock `ubuntu` user at uid 1000, which collides with the most
# common host uid and silently breaks bind-mount ownership. Delete it and create `agent`
# with a build-arg-controlled uid/gid instead; runtime remapping for other host uids
# lands in the entrypoint via gosu.
ARG USER_UID=1000
ARG USER_GID=1000
RUN userdel -r ubuntu 2>/dev/null || true \
 && groupadd -g "${USER_GID}" agent \
 && useradd -m -u "${USER_UID}" -g "${USER_GID}" -s /bin/bash agent

COPY --from=node /usr/local/ /usr/local/
COPY --from=yq /usr/local/bin/yq /usr/local/bin/yq

COPY scripts/install-uv.sh /tmp/install-uv.sh
RUN chmod +x /tmp/install-uv.sh \
 && /tmp/install-uv.sh \
 && rm /tmp/install-uv.sh

ENV LANG=C.UTF-8 \
    NPM_CONFIG_UPDATE_NOTIFIER=false \
    NPM_CONFIG_FUND=false \
    NPM_CONFIG_PREFIX=/home/agent/.npm-global

WORKDIR /workspace
RUN chown agent:agent /workspace

# --- Claude Code layer ---
#
# Transplant the finished payload from the throwaway `claude-code` stage, root-owned from
# the moment it lands — agent only ever needs to *read and execute* here (npm ci output
# is 0755/0644), never write, since the install already happened in that stage. Root
# ownership also matters at runtime: `usermod -u` (used by the entrypoint's uid remap)
# walks the whole home directory re-owning every file that still belongs to agent's old
# uid, and no usermod flag disables that. A file here owned by agent would get caught by
# that walk and force an overlayfs copy-up of this hardlinked payload on every remapped
# start — measured at ~550MB and multiple seconds. Root ownership never matches agent's
# uid, so usermod skips it regardless of what uid agent remaps to.
COPY --from=claude-code --chown=root:root /home/installer/claude-code /home/agent/.agents/claude-code

# Agent-writable directories go LAST. The entrypoint runs as root and inherits this PATH,
# calling `rm`, `mountpoint`, `stat`, `getent`, `chown`, `gosu` by bare name — if the
# agent's own npm/claude-code bin dirs came first, anything the agent writes there would
# shadow a system binary root later executes.
ENV PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/home/agent/.npm-global/bin:/home/agent/.agents/claude-code/node_modules/.bin

# Build-time proof the native binary actually executes — no `|| true`. A missing or
# non-executing binary (e.g. an unshipped arm64 build) fails the build at the layer that
# caused it instead of shipping silently. Runs as root (the payload is root-owned, and
# there's nothing agent-specific about this check); also confirms this RUN creates
# nothing under /home/agent that bootstrap-config.sh would later mistake for
# pre-existing user data.
RUN claude --version

# --- Entrypoint and config persistence ---
#
# Still root here — the entrypoint needs it for the UID/GID remap before dropping to
# `agent` via gosu. entrypoint.sh and bootstrap-config.sh live outside any bind mount so
# a fresh ~/.cbox volume doesn't need them to already exist. No sudo for `agent` at all;
# the escape hatch for host-side maintenance is `docker exec -u root -it claudebox bash`.
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
COPY scripts/bootstrap-config.sh scripts/lib/common.sh /usr/local/lib/cbox/
RUN chmod +x /usr/local/bin/entrypoint.sh /usr/local/lib/cbox/bootstrap-config.sh

# GH_CONFIG_DIR is the one env var confirmed to work — gh reads it directly. Claude Code's
# own config-dir override is deliberately absent here: whether one exists, and whether it
# is honoured, is unverified (see the phase risk notes), so this doesn't promise a
# guarantee the image can't keep. Persistence for Claude Code goes entirely through
# bootstrap-config.sh's symlinks instead.
ENV GH_CONFIG_DIR=/home/agent/.cbox/gh \
    DISABLE_AUTOUPDATER=1 \
    DISABLE_UPDATES=1

# --- cbox helper CLI ---
#
# cbox never proxies Claude Code invocations (see cli/cbox) — it only reports on and
# configures the environment; run `claude` directly. The manifest is baked in read-only
# so `cbox doctor`/`cbox versions` can compare installed-vs-pinned from inside a running
# container, without needing the repo checkout.
ARG BUILD_DATE=unknown
ARG REVISION=unknown

LABEL org.opencontainers.image.title="claudebox" \
      org.opencontainers.image.source="https://github.com/tungbq/claudebox" \
      org.opencontainers.image.created="${BUILD_DATE}" \
      org.opencontainers.image.revision="${REVISION}" \
      org.opencontainers.image.base.name="ubuntu:24.04"

ENV CLAUDEBOX_BUILD_DATE="${BUILD_DATE}" \
    CLAUDEBOX_REVISION="${REVISION}" \
    CBOX_MANIFEST=/usr/local/lib/cbox/claudebox_info.json

COPY cli/ /usr/local/lib/cbox/
COPY claudebox_info.json /usr/local/lib/cbox/claudebox_info.json
RUN chmod +x /usr/local/lib/cbox/cbox /usr/local/lib/cbox/cmd/*.sh \
 && ln -s /usr/local/lib/cbox/cbox /usr/local/bin/cbox \
 && ln -s /usr/local/lib/cbox/cbox /usr/local/bin/claudebox

# Stays root at container start on purpose — entrypoint.sh needs it for the uid/gid
# remap and drops to `agent` itself via gosu before running the requested command.
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["bash"]
