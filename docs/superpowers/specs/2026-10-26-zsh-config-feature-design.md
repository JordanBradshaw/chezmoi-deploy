# zsh-config devcontainer feature, and portable targets in the manifest

Status: approved in conversation (2026-10-26).

## Goal

Make the zsh setup (dotfiles, theme, plugins, tools) portable to any x86_64
devcontainer as a published feature. The image gets only finished binaries
and config: no cargo, Go, zig or build caches. chezmoi decides which tools go
into the devcontainer and which into zssh bundles.

## Concepts

| Concept | Owner | Role |
|---|---|---|
| Manifest | chezmoi `apps/apps.tsv` | what each tool is, where it goes (`tier`, `portable`), how to get it (packages, `release`, `build`) |
| Machine install | chezmoi `scripts/install-apps.sh` | packages, then releases; `--build cargo` is the desktop optimization |
| Bundle assembly | chezmoi-deploy `portable/build.sh` | one layout, two targets: `zssh`, `dev` |
| Delivery | `zssh` / the `zsh-config` feature | push over ssh / install at image build |

Source builds (`build-tools.sh`, `cross/`, the builder image, the qos-orin
profile and lock) stay as the optional path for Jetsons; `build.sh` keeps
using release downloads plus `cross:` rows. Wiring `build-tools.sh` output
into `build.sh` remains rolling-bundles phase 2.

## 1. Manifest: `portable` replaces `bundle`

Column `bundle` (`y`/`-`) becomes `portable`: `zssh`, `dev`, `zssh,dev` or
`-`. The header contract changes, so both repos change together.

- `apps/lib.sh`: `apps_names --portable T` lists rows whose `portable` list
  contains T; `--bundle` is removed.
- Initial values: every former `bundle=y` row becomes `zssh,dev`, except
  `tmux` (`zssh`: only a cross build, no release).
- `apps_test.sh`: `portable` values are known; every `dev` row has a
  `release`; `pipx:` rows are never portable; lock names are `zssh` rows.
- `apps/locks/x86_64-v3.lock` and `.github/workflows/nightly.yml` are removed
  (x86 uses releases). `qos-orin.lock` stays.

## 2. Bundles: `build.sh --target zssh|dev`

- `--target` (default `zssh`) selects `apps_names --portable TARGET`.
- Output: `zsh-portable-ARCH.tar.gz` for `zssh` (unchanged, zssh keeps
  working), `zsh-portable-dev-ARCH.tar.gz` for `dev`; `.version`, `.stamp`
  alongside. The target is part of `input_stamp` and `BUILDINFO`
  (`target T` line).
- `build-tools.sh` builds `apps_names --portable zssh`.
- Removed from chezmoi-deploy: `resolve.yml`. Kept: `lock-diff.sh` (for the
  future qos-orin pipeline), `profiles/x86_64-v3.env` (tests use it).

## 3. The `zsh-config` feature

`features/src/zsh-config/`, published by `features.yml` to
`ghcr.io/jordanbradshaw/chezmoi-deploy/zsh-config` (public).

Options:

| Option | Default | Meaning |
|---|---|---|
| `version` | `latest` | `latest` = the rolling `bundles` release; else a release tag (`bundle-dev-…`) |
| `bundleUrl` | `""` | override the bundle URL (mirrors, offline, tests); `SHA256SUMS` is read from the same directory |
| `defaultShell` | `true` | `chsh` the remote user to zsh |

`install.sh` (root, at image build):

1. Require `uname -m` = x86_64, else fail: `zsh-config: only x86_64 bundles are published`.
2. Install curl, tar, gzip if missing (apt, apk or dnf).
3. Download `zsh-portable-dev-x86_64.tar.gz` and `SHA256SUMS` from
   `https://github.com/JordanBradshaw/chezmoi-deploy/releases/download/<tag>/`
   (`<tag>` = `bundles` for `latest`), or from `bundleUrl`; verify the sum.
4. Unpack to a staging dir; run its `setup.sh ~/.local/share/zsh-config`
   (relocates zsh, disables tools that can't run here); then place, owned by
   `$_REMOTE_USER`, in `$_REMOTE_USER_HOME`:
   - `bin/*` → `~/.local/bin/`
   - `zsh/` → `~/.local/share/zsh-config/zsh/`, linked as `~/.local/bin/zsh`
     and `/usr/local/bin/zsh`
   - `home/.config/*` → `~/.config/`; `home/.zshenv` → `~/.zshenv` (an
     existing one is kept as `~/.zshenv.pre-zsh-config`)
   - `antidote/` → `~/.cache/antidote` (antidote's default home)
   - `VERSION`, `BUILDINFO` → `~/.local/share/zsh-config/`
5. `~/.config/zsh/zshenv.d/05-zsh-config.zsh` exports `ZSH_PORTABLE` (no
   clone or pull at shell start).
6. State: `/var/lib/zsh-config/{zsh,atuin,zoxide}` owned by the user;
   `~/.local/state/zsh`, `~/.local/share/atuin`, `~/.local/share/zoxide` are
   symlinks into it. The feature mounts the volume
   `zsh-config-state-${devcontainerId}` at `/var/lib/zsh-config`, so history
   survives rebuilds (Docker seeds a new volume with the image's ownership).
7. Add `/usr/local/bin/zsh` to `/etc/shells`; `chsh` when `defaultShell`.

`customizations.vscode.settings`: terminal profile `zsh` →
`/usr/local/bin/zsh -l`, made the default.

## 4. Publishing

`publish.yml` in chezmoi-deploy (push to `main`, daily 06:00 UTC, manual):

1. Ubuntu runner; install chezmoi, eget, zsh; check out chezmoi `main` and
   `JordanBradshaw/yupps-zsh`.
2. `ZSSH_YUPPS_DIR=… CHEZMOI_SRC=… portable/build.sh --target dev --arch x86_64`.
3. Compare `VERSION` with the `bundles` release's `.version`; equal → stop.
4. Run the feature test against the new bundle (gate).
5. Upload `zsh-portable-dev-x86_64.tar.gz`, `.version`, `SHA256SUMS`,
   `BUILDINFO` to the rolling release `bundles` (assets replaced) and the
   immutable release `bundle-dev-<date>-<version>`.

## 5. Tests

- chezmoi `apps_test.sh`: section 1.
- chezmoi-deploy `build_tools_test.sh` / `portable_test.sh`: `--target`,
  bundle names, `--portable` selection, stamp includes target.
- chezmoi-deploy `feature_test.sh`: JSON valid, `bash -n install.sh`; with
  `FEATURE_E2E=1` and a bundle path, run `install.sh` in `ubuntu:24.04` and
  `debian:12` (remote user `dev`, `bundleUrl` = `file://` mount) and check
  `~/.local/bin` tools run, `zsh -i -c` loads the theme offline
  (`--network none` after install), login shell is `/usr/local/bin/zsh`,
  history lands in `/var/lib/zsh-config/zsh/history`.

## Non-goals

aarch64 dev bundles; an in-container update command; `build.sh --source build`.
