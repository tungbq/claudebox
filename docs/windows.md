# Windows guide

Everything in [`usage.md`](usage.md) and [`build.md`](build.md) applies on Windows — this
page covers only what differs: shell syntax, line endings, SSH forwarding, and where to
keep your code.

## Prerequisites

- **Docker Desktop with the WSL2 backend.** The image is Linux (`linux/amd64`,
  `linux/arm64`); it does not run as a Windows container. Check
  *Settings → General → Use the WSL 2 based engine*.
- **WSL2 with a distro installed** (`wsl --install -d Ubuntu`). Docker Desktop needs it
  for the engine regardless of where you keep your code.
- Give the Docker VM enough memory — an emulated arm64 build is memory-hungry
  (*Settings → Resources*).

Verify the engine is Linux-side:

```powershell
docker version --format '{{.Server.Os}}/{{.Server.Arch}}'   # expect linux/amd64
```

## Line endings — read this before building

Shell scripts in this repo are copied into the image and executed by Linux. If Git
checks them out with CRLF, the build fails at the first `RUN`:

```
/usr/bin/env: 'bash\r': No such file or directory
```

The repo ships a `.gitattributes` (`* text=auto eol=lf`) that prevents this, so a fresh
clone is fine even with `core.autocrlf=true` set globally.

**If you cloned before that file existed**, your working tree may still hold CRLF. Check
and repair:

```powershell
git ls-files --eol entrypoint.sh cli/cbox      # want w/lf, not w/crlf
```

```powershell
git rm --cached -r .
git reset --hard
```

Configure your editor to keep LF — `.editorconfig` already declares `end_of_line = lf`.

## Shell syntax by terminal

The docs use `$PWD`, which is POSIX. Translate per shell:

| Shell | Bind-mount the current directory |
|---|---|
| PowerShell | `-v "${PWD}:/workspace"` |
| cmd.exe | `-v "%cd%:/workspace"` |
| Git Bash | `-v "/$(pwd):/workspace"` (note the leading slash) |
| WSL shell | `-v "$PWD:/workspace"` — unchanged |

A full run in PowerShell:

```powershell
docker run --rm -it `
  -v "${PWD}:/workspace" `
  -v claudebox-config:/home/agent/.cbox `
  claudebox:dev
```

Two gotchas specific to Windows shells:

- **Git Bash rewrites paths that look Unix-like.** `-v "$PWD/src":/workspace` gets
  mangled into a Windows path Docker can't resolve. Prefix with an extra `/`, or set
  `MSYS_NO_PATHCONV=1` for the command.
- **PowerShell 5.1 mangles nested quoting**, so `sh -c '...'` arguments can arrive
  split. Use the stop-parsing token (`docker --% run ...`) or put the complex command in
  a script file. PowerShell 7 handles this better.

## Where to keep your code

Both locations work. The trade-off is I/O speed:

| Location | Ownership seen by the container | Notes |
|---|---|---|
| Windows drive (`D:\code\proj`) | `uid=0 gid=0`, mode `0777` (synthesized) | Works — see below. Crosses the VM boundary: noticeably slower for large repos, `npm install`, and file watching |
| WSL2 filesystem (`/home/you/proj`) | real `uid=1000 gid=1000` | Native ext4 speed; run `docker` from inside the WSL shell |

For anything write-heavy, keep the repo inside WSL2 and drive Docker from the WSL shell,
where every command in `usage.md` works verbatim. WSL2's default user is uid 1000,
exactly the case the entrypoint's config-volume `chown` covers on first use.

## Mount ownership on a Windows drive

Docker Desktop exposes Windows-drive bind mounts as root-owned with mode `0777` — the
ownership is synthesized by the VM's file sharing layer rather than read from NTFS. The
`agent` user (uid 1000) can read and write everything, and files it creates land on the
host owned by your Windows account as usual.

The image accounts for this: the entrypoint keeps `agent` at uid 1000 without warning,
and `cbox doctor` reports

```
workspace      /workspace           mounted, writable (ownership managed by host)
```

which counts as healthy. A mount that is root-owned *and* not world-writable — a real
Linux-host misconfiguration — is still reported as an error.

> If you compare notes with other Windows users: with
> `[automount] options = "metadata"` in `/etc/wsl.conf`, a directory whose permissions
> were set from inside WSL keeps real Linux ownership in NTFS extended attributes, and
> that directory mounts as uid 1000 instead. Either way the container behaves the same.

## SSH and git

**Agent forwarding does not work from a Windows shell.** `SSH_AUTH_SOCK` on Windows is a
named pipe, not a Unix socket, so `-v "$SSH_AUTH_SOCK":/ssh-agent` has nothing to mount.
Options, best first:

1. **Run from WSL.** Start `ssh-agent` inside the distro and use the normal forwarding
   command from `usage.md` — a real Unix socket exists there.
2. **Mount keys read-only** — opt-in and weaker, since a container running untrusted
   agent content gets an unforwarded private key:

   ```powershell
   docker run --rm -it `
     -v "${PWD}:/workspace" `
     -v claudebox-config:/home/agent/.cbox `
     -v "${env:USERPROFILE}\.ssh:/home/agent/.ssh:ro" -e CBOX_LINK_SSH=1 `
     claudebox:dev
   ```

## Building on Windows

`docker build -t claudebox:dev .` works from any of the shells above once line endings
are correct. Two notes:

- The verification scripts (`scripts/verify-versions.sh`, `smoke-test.sh`) are bash and
  need `jq`. Run them from WSL or Git Bash, not PowerShell.
- Building from a Windows-drive checkout sends the context across the VM boundary and is
  slower than the same build from a WSL2 checkout.

## Troubleshooting

- **`/usr/bin/env: 'bash\r': No such file or directory` during build** — CRLF line
  endings. See the line-endings section above.
- **`docker: invalid reference format` or a mount that silently lands empty** — path
  mangling or quoting. Check the shell-syntax table; in Git Bash try the leading-slash
  form.
- **`error during connect ... //./pipe/dockerDesktopLinuxEngine`** — Docker Desktop isn't
  running, or the WSL2 engine is off.
- **The container starts but `/workspace` is empty** — on older Docker Desktop versions,
  a Windows drive needs to be shared under *Settings → Resources → File sharing*.
- **Builds or file watching are very slow** — you're on a Windows-drive checkout. Move the
  repo into WSL2.
- **`bash` exits immediately, or `claude` prints `Error: stdin is not a terminal`** —
  your terminal isn't giving Docker a TTY. Probe it with
  `docker run --rm -it ubuntu:24.04 sh -c 'test -t 0 && echo TTY_OK || echo NO_TTY'`.
  In Git Bash/MinTTY, prefix commands with `winpty`; in a WSL shell or Windows Terminal's
  PowerShell tab it works directly. Piping stdin (VS Code tasks, CI runners) never
  allocates one.
