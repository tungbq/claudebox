# Using claudebox on an existing project

No setup step is needed on the repo's side — the workspace mount is a direct bind mount,
not a copy, so pointing it at a real project just works.

## Run it from inside your repo

```bash
cd ~/code/your-existing-project

docker run --rm -it \
  -v "$PWD":/workspace \
  -v claudebox-config:/home/agent/.cbox \
  claudebox:dev
```

`$PWD` is your repo root, so `agent` sees exactly what you see: `.git`, existing
branches, `node_modules`, build output, everything. Edits made inside the container land
on the host immediately (it's the same filesystem, not a synced copy), and anything
`claude` commits or changes is visible to your host git tools the moment it happens.

## What carries over automatically

- **Git identity and `gh` auth** — once set up once (see [`usage.md`](usage.md#logging-in)),
  they persist in the `claudebox-config` volume across every project you mount, not just
  this one.
- **`.gitignore`, hooks, existing branches** — untouched, since this is your real `.git`,
  not a clone.

## What doesn't

- **Ownership.** The entrypoint remaps `agent` to match `$PWD`'s owner on every start. If
  your project directory is owned by someone other than you (root-owned Docker Desktop
  quirks, a directory another tool created as root), see the ownership troubleshooting in
  [`usage.md`](usage.md#troubleshooting) before assuming something's broken.
- **Native builds.** This image intentionally has no compiler (see the README's
  ["what's deliberately not" section](../README.md#whats-in-the-image--whats-deliberately-not)).
  If your project's install step needs `node-gyp` or a source build without a prebuilt
  wheel, it'll fail here even though it works on your host.

## Multiple projects, one login

Reuse the same `claudebox-config` volume across every project — the Claude login and git
identity are shared, and only `/workspace` changes between runs:

```bash
# project A
docker run --rm -it -v ~/code/project-a:/workspace -v claudebox-config:/home/agent/.cbox claudebox:dev

# project B, same day or months later — no re-login needed
docker run --rm -it -v ~/code/project-b:/workspace -v claudebox-config:/home/agent/.cbox claudebox:dev
```

If you'd rather keep separate logins or configs per project (e.g. different Claude
accounts for work vs. personal repos), use a different volume name per project instead of
sharing `claudebox-config`.
