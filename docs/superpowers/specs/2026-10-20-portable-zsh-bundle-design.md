# Portable zsh bundle (zssh) design

## Goal

Get this machine's zsh setup (plugins, aliases, yupps theme, CLI tools) on
hosts reached over ssh, without installing anything on them:

- Work Jetsons (aarch64, Ubuntu 18.04 to 22.04): shared, no internet.
- Home Raspberry Pis (aarch64 or armv7l).

Secrets must never leave this machine. Only cross-compiled binaries and
plain dotfiles are shipped.

xxh was rejected: it builds every package for x86_64 (`packages_install`
hardcodes the arch) and `xxh-shell-zsh` only knows x86_64 and armv7l.

## Components

- `scripts/portable/build.sh --arch ARCH`: builds
  `~/.cache/zsh-portable/dist/zsh-portable-ARCH.tar.gz` plus a `.version`
  content hash. It rebuilds only when files under `home/` or
  `scripts/portable/` change, or with `--force` or `--refresh`.
- `scripts/portable/tools.tsv`: tools fetched with eget per arch. musl builds
  come first. Each download's ELF CPU type is checked, because eget asset
  filters can override `--system`.
- `scripts/portable/remote/setup.sh`: runs on the host after unpacking.
  Relocates zsh-bin and disables tools that can't run there. Only loader
  failures count: exit 126/127, or glibc/shared-library errors. Tools that
  start and then complain stay. Each tool is checked with a throwaway HOME,
  because some (lnav) write config when they start.
- `scripts/portable/cross/NAME.sh ARCH OUT`: builds tools that have no
  prebuilt release, used by `tools.tsv` rows with repo `cross:NAME`.
  `tmux.sh` builds tmux 3.5a for aarch64 in the Yocto SDK container, with
  static libevent and ncurses, so it needs only glibc.
- `scripts/portable/remote/enter`: points XDG dirs, ZDOTDIR, HISTFILE,
  ANTIDOTE_HOME and ATUIN_HOME into the bundle, then execs zsh.
- `home/dot_local/bin/executable_zssh`: `zssh [--rebuild|--refresh] [ssh
  options] host`. Probes `uname -m` and the remote version, builds, uploads
  through ssh stdin only when the version differs, then opens the session.
  One ControlMaster connection is used for all three steps.

## Bundle layout

```
app/                       replaced atomically on update
  VERSION enter setup.sh
  zsh/                     romkatv/zsh-bin v6.1.1 (zsh 5.8), static
  bin/                     tools for the target CPU
  home/.zshenv             chezmoi archive of an allowlist
  home/.config/{zsh,atuin,bat,direnv,eza,fd,lsd,ripgrep}
  home/.config/zsh/.antidote
  antidote/                plugin repos, without .git
state/                     history, zoxide/atuin data, caches; kept
```

On the host this lives in `~/.zsh-portable` (`ZSSH_REMOTE_DIR` to change).
Deleting it removes everything. The generated `.zsh_plugins.zsh` is not
shipped; `.zshrc` regenerates it offline on first start.

## Secrets

1. chezmoi runs with a throwaway config (`hasSecrets=false`, no age
   identity) and `--exclude=encrypted,scripts,externals`.
2. Only allowlisted paths are exported. git config is left out, since its
   options can break older git on the hosts.
3. `check_secrets` fails the build on `*.age`, `secrets/`, key or
   credential files, `AGE-SECRET-KEY-` in text files, or any value of 8+
   characters from `~/.config/secrets/env`. Only the variable name is
   reported, never the value.

## Host-specific changes

- The `ssh-agent` plugin is dropped from the bundled plugin list.
- `ATUIN_UPDATE_CHECK=false`.
- `.zshenv` keeps an inherited `HISTFILE`.

## Hosts

Work Jetsons run Quantum-Systems OS: a Yocto/OE4T build with glibc 2.39,
not Ubuntu. The SDK container (`gitlab.quantum-systems.com:5050/ai/repo/
devcontainer-yocto`, sysroot `/opt/nos/sysroots/armv8a-oe4t-linux`) has the
target's libraries but no shell or coreutils. All bundled tools are static
except `delta` and `eza` (glibc 2.18 or newer), so nothing is cross-compiled.
The images may lack gzip, so zssh probes the host for `tar` and `gzip`.
Without gzip it sends an uncompressed tar; without tar it fails before
uploading.

## Testing

`bash tests/portable_test.sh` runs unit tests and zssh against a stub ssh
and builder.

`PORTABLE_E2E=1 PORTABLE_E2E_ARCHES="x86_64 aarch64 armv7l qos"` builds real
bundles and runs them with `--network none` on ubuntu:22.04, arm64
ubuntu:18.04 (JetPack 4 base), arm/v7 debian:bookworm, and `qos`. `qos` runs
the aarch64 bundle in the Yocto SDK container, with
`QEMU_LD_PREFIX=<sysroot>` so every binary loads the Jetson's libraries. The test checks
the prompt, aliases, tools and plugins, and that nothing is written outside
`~/.zsh-portable`. The arm targets need `tonistiigi/binfmt --install
arm64,arm`.
