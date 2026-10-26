# Rolling cross-built zsh bundles and the zsh-config devcontainer feature

Status: draft for review (2026-10-26). Sections 1 and 2 were agreed in
conversation; sections 3-7 are new here.

## Goal

1. **Builder containers** cross-compile the CLI tools for each target
   profile, always at the latest upstream version ("rolling"), tuned for the
   target CPU, and assemble the zsh-portable bundles that `zssh` deploys.
2. The **x86_64-v3 bundle doubles as a devcontainer feature**: adding it to
   any `devcontainer.json` gives the container the full zsh environment
   (dotfiles, antidote plugins, yupps-zsh and its theme, tools), loaded
   automatically.

## Decisions (from the brainstorm)

| Question | Decision |
|---|---|
| What the containers serve | Their own shell, plus Jetson target binaries |
| Where compiling happens | In builder containers, never on the laptop's host toolchain |
| Where builders run | One builder image, used as a local devcontainer, by `zssh` on the laptop (`docker run`), and by scheduled CI |
| Publishing | Split: GitHub (public) for the feature and x86_64-v3; work GitLab for qos-orin (needs the private Yocto SDK image) |
| What the feature installs | Full shell and tools (the bundle), not only the plugin |
| First target profiles | `qos-orin`, `x86_64-v3` |

## 1. Architecture

```
                    ┌──────────── builder image (one definition) ────────────┐
features/src/zsh-builder  ──►  rustup (+targets) · zig + cargo-zigbuild · Go · eget
                               · build deps · your shell (zsh-config feature)
   stacked on:  ubuntu:24.04          →  ghcr.io/jordanbradshaw/zsh-builder        (x86_64-v3)
                devcontainer-yocto    →  gitlab…/zsh-builder-qos (has /opt/nos SDK) (qos-orin)
                    └──────────────────────────────────────────────────────────┘
used three ways:
  1. local devcontainer  — open the repo in it, debug recipes, run builds by hand
  2. zssh on the laptop  — `docker run` the builder with repo + cache mounted
  3. scheduled CI        — nightly: GitHub (x86_64-v3), work GitLab (qos-orin)
                           → publish rolling bundles + tools.lock

inside the builder:
  scripts/portable/profiles/<profile>.env      arch, rust target, CPU flags, libc
  scripts/portable/tools.tsv  (+ source column) crate: / go: / cross: / release
  build-tools.sh --profile P   latest version per tool → cache keyed by
                               name+version+profile+recipe → only changes rebuild
  build.sh --profile P         bundle = built tools (+ eget for "release" rows)
                               → zsh-portable-<profile>.tar.gz + VERSION + tools.lock

zssh root@jetson   host→profile → newest bundle (local build, else published)
                   → same deploy as today (.version mismatch → push)
```

- Profiles replace `--arch` as the build key: `qos-orin` and a generic
  aarch64 build are different bundles.
- Rolling: versions are not pinned in the repo; each build resolves
  "latest" and records the result in `tools.lock` inside the bundle. A tool
  whose build fails keeps its last good cached build, else falls back to its
  eget release.
- One builder feature for both variants: it enables the SDK recipes (tmux,
  nvtop) only when `/opt/nos` exists. The GitHub variant never needs work
  credentials.

## 2. The `zsh-config` feature (consumer side)

```jsonc
"features": {
  "ghcr.io/jordanbradshaw/zsh-config/zsh-config:1": {
    "version": "latest",        // rolling bundle channel, or a bundle version
    "defaultShell": true,       // the remote user's login shell
    "persistState": true        // history/atuin/zoxide survive rebuilds
  }
}
```

`install.sh` (root, at image build):

1. Require x86_64; fail clearly elsewhere ("only the x86_64-v3 profile is
   published"). The bundle is static musl, so any distro works. Needs curl
   or wget; installs one with the image's package manager if missing.
2. Download `zsh-portable-x86_64-v3.tar.gz` for `version` from the GitHub
   release channel; verify against the published `SHA256SUMS`.
3. Unpack into `$_REMOTE_USER_HOME/.zsh-portable`, owned by the remote user
   (the layout and `enter` script zssh already uses and e2e-tests).
4. `/usr/local/bin/zsh-config` wrapper → `~/.zsh-portable/enter`; add it to
   `/etc/shells`; `chsh` the remote user when `defaultShell`.

Automatic loading:

- Login shell via `chsh`: `docker exec … bash -l`, SSH and
  `devcontainer exec` land in it.
- VS Code: the feature's `customizations.vscode.settings` adds a
  `zsh-config` terminal profile (the wrapper) and makes it the default.
- Any other `zsh` in the image: `install.sh` writes the managed
  `# >>> zsh-config >>>` block into the user's `~/.zshenv`, pointing
  `XDG_CONFIG_HOME`/`ZDOTDIR` into the bundle.
- `ZSH_PORTABLE` is set: no clone, pull or other network at shell start.

`persistState`: the feature declares the named volume
`zsh-config-state-${devcontainerId}` at `~/.zsh-portable/state`.

Updates: an image rebuild picks up the newest bundle when `version` is
`latest`; `zsh-config-update` in the container swaps in a newer bundle
without a rebuild.

This repo's `.devcontainer/devcontainer.json` replaces its chezmoi
`postCreateCommand` with the feature.

## 3. Builder: profiles, recipes, `build-tools.sh`

### Profiles (`scripts/portable/profiles/<name>.env`)

```sh
# qos-orin.env
PROFILE_ARCH=aarch64
RUST_TARGET=aarch64-unknown-linux-gnu.2.39   # zigbuild: pin glibc to QOS's
RUST_CPU=cortex-a78ae
GO_ENV="GOARCH=arm64 CGO_ENABLED=0"
NEEDS_SDK=1                                   # cross: recipes via /opt/nos

# x86_64-v3.env
PROFILE_ARCH=x86_64
RUST_TARGET=x86_64-unknown-linux-musl         # static
RUST_CPU=x86-64-v3
GO_ENV="GOARCH=amd64 GOAMD64=v3 CGO_ENABLED=0"
NEEDS_SDK=0
```

`RUSTFLAGS="-C target-cpu=$RUST_CPU"`, fat LTO and one codegen unit as in
`install-apps.sh --build cargo`, but for a named CPU, never `native`.

### Recipes (`tools.tsv` gains a `source` column)

| source | build |
|---|---|
| `crate:NAME[:BIN][:ARGS]` | `cargo zigbuild --release --locked --target $RUST_TARGET` from the crates.io source of the latest version; ARGS e.g. `--no-default-features --features rustls` |
| `go:MODULE/cmd/x` | `go install MODULE@latest` with `GO_ENV`, `-trimpath -ldflags=-s` |
| `cross:NAME` | `cross/NAME.sh` (existing; needs the SDK) |
| `release` | today's eget path, unchanged |

Each existing row is classified once (Rust crates → `crate:`, Go → `go:`,
C/C++ such as lnav → `release`). Rows keep their eget columns as the fallback.

### `build-tools.sh --profile P [--resolve | --locked] [--only NAME…]`

1. Versions: `--locked` (default) builds exactly
   `scripts/portable/locks/<profile>.lock`; `--resolve` looks up the latest
   version per tool (crates.io API `max_stable_version`, Go proxy
   `@latest`, GitHub latest release for `release` rows) and rewrites the
   lock. A tool missing from the lock is resolved even under `--locked`.
2. Cache: `$XDG_CACHE_HOME/zsh-portable/tools/<profile>/<name>/<version>-<recipehash>/`.
   A hit is reused; a miss is built.
3. Verify each binary: ELF arch matches the profile; qos-orin: highest
   required `GLIBC_` symbol version ≤ 2.39; x86_64-v3: statically linked.
4. Failure: keep the newest good cached build of that tool, else its eget
   release; never fail the whole run for one tool. Under `--resolve` a
   failed tool keeps its previous lock entry.
5. Output: `<out>/bin/<name>` for every tool, plus `tools.lock` (name,
   source, version, sha256, how it was obtained) that goes into the bundle.

### Bundles

`build.sh --profile P` (replaces `--arch`; `--arch` stays as an alias for
the eget-only path) takes tools from `build-tools.sh`, everything else as
today (static zsh, dotfiles, antidote plugins, yupps-zsh, secret scan).
`VERSION` changes whenever any tool's version changes, so `zssh` updates.

### Builder feature (`features/src/zsh-builder`)

Installs rustup + the profile targets, zig + cargo-zigbuild, Go, git, curl,
eget, build-essential/pkg-config, and the `zsh-config` feature for the
interactive shell. Builder images are built in CI from a two-line
Dockerfile per variant (`FROM base` + `RUN features/src/zsh-builder/install.sh`),
so no Node/devcontainer CLI is needed to produce them.

## 4. Gated rolling CI and publishing

Rolling, but reviewed: CI proposes version changes as a pull request and
publishes only what was merged.

- **Nightly check** (GitHub Actions, zsh-config repo): in the builder image,
  `build-tools.sh --profile x86_64-v3 --resolve` resolves the latest
  version of every tool and rewrites `scripts/portable/locks/x86_64-v3.lock`.
  If the lock changed, it builds the changed tools (to prove they build and
  pass the ELF checks) and opens or updates one pull request,
  `tools: rolling update <date>`. The PR description lists each change
  (`ripgrep 15.2.0 → 15.3.0`) and any tool whose build failed (that tool
  keeps its old lock entry).
- **Publish on merge** (push to `config` touching a lock, `home/` or
  `scripts/portable/`): build with `build.sh --profile x86_64-v3 --locked`,
  which uses exactly the lock's versions; upload to the rolling release
  `bundles` (replaces assets) and an immutable release
  `bundle-<date>-<version>`, with `SHA256SUMS` and the lock.
- **Feature publishing**: `devcontainers/action` when a
  `devcontainer-feature.json` version changed.
- **Builder image** `ghcr.io/jordanbradshaw/zsh-builder`: rebuilt when
  `features/src/zsh-builder/` changes.
- **Work GitLab** (phase 4): the same two jobs for `qos-orin`, with merge
  requests, publishing to the generic package registry
  `zsh-portable/qos-orin/{latest,<version>}`.

`build-tools.sh` therefore has two version modes: `--resolve` (look up
latest, write the lock) and `--locked` (build exactly the lock; the default
for `build.sh`). Local `zssh` builds use `--locked` too, so the laptop
deploys what was reviewed.

## Rolling back

- **The whole concept**: everything lives on the branch `rolling-bundles`
  in its own worktree (`~/repos/zsh-config-rolling`), on top of one
  baseline commit that snapshots the `config` working tree as it was. The
  `config` branch and its working tree are never touched. Rollback =
  `git worktree remove ~/repos/zsh-config-rolling && git branch -D
  rolling-bundles`. Nothing is pushed until you say so, so no CI runs and
  nothing is published before that.
- **A bad tool update** (after adoption): revert the merged lock PR; the
  next publish builds the previous versions. Already-published bundles stay
  as immutable releases, so a devcontainer can pin `"version":
  "bundle-<date>-<version>"`.
- **Per machine**: `zssh` keeps the previous bundle on the host until the
  new one unpacked cleanly (as today).

## 5. zssh changes

- Profile per host: probe `uname -m` and `/etc/os-release`; QOS → `qos-orin`;
  x86_64 → `x86_64-v3`; anything else → today's `--arch` path. Override in
  `~/.config/zssh/profiles` (`host-glob profile`).
- Getting the bundle, first that works:
  1. local build: repo present and docker available → run the builder image
     with the repo and cache mounted (`build.sh --profile P`);
  2. published: GitHub release (x86_64-v3) or GitLab package with
     `$GITLAB_TOKEN` (qos-orin);
  3. today's eget-only build.
- Deploy unchanged (`.version` comparison, push, `setup.sh`).

## 6. Testing

- Unit (bash, stubs, like `install_apps_test.sh`): profile parsing; version
  resolution per source; cache hit/miss keyed by version and recipe;
  fallback to the last good build, then eget; ELF/glibc/static checks;
  `tools.lock`; zssh profile choice and bundle sources in order.
- Feature: `install.sh` in docker on `ubuntu:24.04` and `debian:12` with a
  local bundle: wrapper, `/etc/shells`, `chsh`, `~/.zshenv` block, VS Code
  settings in `devcontainer-feature.json`, state volume declared, arch
  check; then a login shell: yupps functions, theme, `rg --version`, no
  network access needed (`--network none`).
- e2e: qos-orin bundle under QEMU with the QOS sysroot (existing qos e2e);
  `readelf` checks for glibc ≤ 2.39 and aarch64.
- Every existing suite keeps passing.

## 7. Phases (each gets its own implementation plan)

1. **Builder locally**: profiles, `source` column, `build-tools.sh`, builder
   feature and Dockerfile; build `x86_64-v3` tools in the builder on the
   laptop.
2. **Bundle by profile + zsh-config feature**: `build.sh --profile`,
   feature `install.sh`, tests; this repo's devcontainer uses it from a
   local bundle.
3. **GitHub CI**: builder image, nightly bundles, rolling and immutable
   releases, feature publishing.
4. **qos-orin**: `zsh-builder-qos`, work GitLab pipeline, zssh profile
   detection and published-bundle download.

## Open points

- Work GitLab location for the qos-orin pipeline and the `zsh-builder-qos`
  image (which group/repo, and whether CI there may pull a public GitHub
  repo). Until decided, phase 4 is blocked; phases 1-3 are not.
- tmux for `x86_64-v3`: no recipe today (only `cross:tmux` for QOS). Option:
  a static musl `cross:tmux-static` recipe in the builder.
- Crates that need OpenSSL: build with their `rustls` feature where offered,
  per-recipe ARGS otherwise.
- armv7 and Pi profiles are out of scope for now; the profile design leaves
  room for them.
