#!/usr/bin/env bats
# Exercises the cbox CLI and entrypoint against a built image — not a source-level unit
# test, since cbox's whole job is reading real container state (manifest, symlinks,
# mounts). Run with:
#   bats tests/test-cbox.bats
# Set IMAGE to target a different tag (default: claudebox:dev).

IMAGE="${IMAGE:-claudebox:dev}"

@test "cbox bare prints usage and exits 0" {
  run docker run --rm "$IMAGE" cbox
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage: cbox"* ]]
}

@test "cbox help exits 0" {
  run docker run --rm "$IMAGE" cbox help
  [ "$status" -eq 0 ]
}

@test "claudebox alias resolves identically to cbox" {
  run docker run --rm "$IMAGE" claudebox help
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage: cbox"* ]]
}

@test "unknown subcommand prints usage to stderr and exits 1" {
  run docker run --rm "$IMAGE" cbox bogus
  [ "$status" -eq 1 ]
  [[ "$output" == *"unknown command: bogus"* ]]
}

@test "cbox versions reports every pinned tool as ok on a clean image" {
  run docker run --rm "$IMAGE" cbox versions
  [ "$status" -eq 0 ]
  [[ "$output" == *"claude-code"* ]]
  [[ "$output" != *"DRIFT"* ]]
  [[ "$output" != *"MISSING"* ]]
}

@test "cbox versions detects a deliberately drifted version" {
  # [RT-13] jq-set the pin at runtime instead of sed'ing a hardcoded literal — the
  # literal survives every version bump and the weekly drift-check bot forever, silently
  # turning this case into a false pass once the real pin moves.
  run docker run --rm "$IMAGE" bash -lc '
    jq ".tools[\"claude-code\"].version = \"9.9.9\"" /usr/local/lib/cbox/claudebox_info.json > /tmp/drifted.json
    CBOX_MANIFEST=/tmp/drifted.json cbox versions
  '
  [ "$status" -eq 1 ]
  [[ "$output" == *"DRIFT"* ]]
}

@test "cbox doctor exits 0 healthy with no mount" {
  run docker run --rm "$IMAGE" cbox doctor --quiet
  [ "$status" -eq 0 ]
  # Substring, not exact match: docker itself prints a platform-mismatch warning to
  # stderr (captured into $output by bats) when running an arm64 image under QEMU on
  # an amd64 host — same reasoning as the *"degraded"* check just below.
  [[ "$output" == *"healthy"* ]]
}

@test "cbox doctor exits 2 degraded when the workspace is root-owned" {
  scratch="$(mktemp -d)"
  docker run --rm -v "$scratch":/scratch alpine chown 0:0 /scratch
  run docker run --rm -v "$scratch":/workspace "$IMAGE" cbox doctor --quiet
  # chown'd to root above — reclaim ownership before a plain host-user rm can touch it.
  docker run --rm -v "$scratch":/scratch alpine chown -R "$(id -u):$(id -g)" /scratch
  rm -rf "$scratch"
  [ "$status" -eq 2 ]
  [[ "$output" == *"degraded"* ]]
}

@test "container starts on a fresh root-owned named volume at the default uid" {
  # Named volumes are always root-owned by Docker on first use, independent of the
  # container's default uid — this reproduces that without depending on the host
  # user's actual uid (a bind-mounted mktemp dir would just inherit it and never
  # exercise the bug).
  vol="cbox-test-vol-$$"
  docker volume create "$vol" >/dev/null
  docker run --rm -v "$vol":/scratch alpine chown 0:0 /scratch

  run docker run --rm -v "$vol":/home/agent/.cbox "$IMAGE" cbox doctor --quiet

  docker volume rm "$vol" >/dev/null
  [ "$status" -eq 0 ]
  [[ "$output" == *"healthy"* ]]
}

@test "cbox info reports the pinned image name" {
  run docker run --rm "$IMAGE" cbox info
  [ "$status" -eq 0 ]
  [[ "$output" == *"claudebox"* ]]
}

@test "forced uid/gid remap reports the requested identity" {
  # [RT-6] Every uid-remap guard sits behind a branch neither the implementer (uid 1000)
  # nor a root-owned-mount fixture ever exercises. Force it explicitly.
  scratch="$(mktemp -d)"
  run docker run --rm -e HOST_UID=1234 -e HOST_GID=1234 -v "$scratch":/workspace "$IMAGE" id
  rm -rf "$scratch"
  [ "$status" -eq 0 ]
  [[ "$output" == *"uid=1234"* ]]
  [[ "$output" == *"gid=1234"* ]]
}

@test "SSH linking starts successfully and re-running starts successfully again" {
  # [RT-5] The exact documented invocation. Before the mountpoint-safe fix, the second
  # run hit EBUSY on the bind-mounted ~/.ssh and left the container permanently unable
  # to start.
  ssh_dir="$(mktemp -d)"
  echo "fake-private-key" > "$ssh_dir/id_ed25519"
  chmod 600 "$ssh_dir/id_ed25519"
  cbox_vol="$(mktemp -d)"

  run docker run --rm -e CBOX_LINK_SSH=1 -v "$ssh_dir":/home/agent/.ssh:ro \
    -v "$cbox_vol":/home/agent/.cbox "$IMAGE" true
  first_status="$status"

  run docker run --rm -e CBOX_LINK_SSH=1 -v "$ssh_dir":/home/agent/.ssh:ro \
    -v "$cbox_vol":/home/agent/.cbox "$IMAGE" true
  second_status="$status"

  rm -rf "$ssh_dir" "$cbox_vol"
  [ "$first_status" -eq 0 ]
  [ "$second_status" -eq 0 ]
}
