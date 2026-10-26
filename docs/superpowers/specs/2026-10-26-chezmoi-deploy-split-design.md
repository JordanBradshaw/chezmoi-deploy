# Split zsh-config into chezmoi (dotfiles, apps, versions) and chezmoi-deploy (portable builds)

Status: draft for review (2026-10-26).

## Goal

`JordanBradshaw/zsh-config` (branch `rolling-bundles`) currently holds two
products: the chezmoi dotfiles and the machinery that turns them into
portable bundles, devcontainer features and builder images. Split it in two:

- **chezmoi** (`JordanBradshaw/chezmoi`): dotfiles, the app manifest and the
  per-profile version locks. Works on its own on any machine; contains no
  cross-build logic.
- **chezmoi-deploy** (`JordanBradshaw/chezmoi-deploy`, this wrapper): builder
  feature and images, cross recipes, target profiles, bundle assembly,
  the `zsh-config` consumer feature, and the CI that builds and publishes.
  It reads a chezmoi checkout as input and never hand-edits it.

Success: chezmoi applies and its tests pass with no wrapper present; the
wrapper builds a bundle for any chezmoi ref given only a path to it.

## Decisions

| Question | Decision |
|---|---|
| Where versions live | App manifest and `locks/<profile>.lock` in chezmoi |
| How the wrapper gets chezmoi | Path/ref input (`CHEZMOI_SRC`), no submodule |
| Where `zssh` lives | Thin `zssh` stays a chezmoi dotfile |
| App lists | `install-apps.sh` table and `tools.tsv` merge into one manifest |
| History | Split with `git filter-repo`, history kept |
| Rolling CI | chezmoi's nightly workflow calls the wrapper's reusable workflow; lock PRs open in chezmoi |
| Order | Build the seam inside zsh-config first, test it, then split mechanically |

## 1. Ownership

```
JordanBradshaw/chezmoi                     JordanBradshaw/chezmoi-deploy
├─ .chezmoiroot → home                     ├─ portable/      build.sh build-tools.sh builder.sh lib.sh
├─ home/            dotfiles, thin zssh    │                 cross/ profiles/ remote/{setup.sh,enter}
├─ apps/apps.tsv    the one manifest       ├─ features/src/zsh-builder/
├─ apps/lib.sh      manifest + release     ├─ features/src/zsh-config/     (consumer feature)
├─ apps/locks/<profile>.lock               ├─ features/builder/<arch>.Dockerfile
├─ scripts/install-apps.sh  (reads apps/)  ├─ .github/workflows/ resolve.yml publish.yml
├─ scripts/kde/, merge-zsh-history.py      │                    builder-image.yml features.yml
├─ install.sh, eget.sh, other/             ├─ tests/ build_tools_test.sh portable_test.sh
├─ .github/workflows/nightly.yml           │        fixtures/chezmoi/   (minimal chezmoi tree)
└─ tests/ zsh/ install_apps fonts tmux     └─ docs/superpowers/ (portable specs and plans)
         history_merge zsh_startup apps
```

`home/dot_eget.toml` stays a dotfile (eget's own config for manual use); it
is not part of the manifest.

## 2. The interface

The wrapper reads exactly these from `CHEZMOI_SRC` (the chezmoi repo's top
level, not `home/`):

| Path | Used by |
|---|---|
| `home/` | `build.sh`: `chezmoi archive` / `execute-template` with `--source=$CHEZMOI_SRC` |
| `apps/apps.tsv` | `build-tools.sh`, `build.sh`: rows with `bundle=y` |
| `apps/lib.sh` | manifest accessors and `fetch_release`/`elf_arch` |
| `apps/locks/<profile>.lock` | `build-tools.sh` reads; `--resolve` rewrites it in place |

Resolution, first match wins: `--chezmoi DIR`, `$CHEZMOI_SRC`, the git top
level of `chezmoi source-path`. The wrapper fails clearly if
`apps/apps.tsv` is missing or its header does not match the column set it
knows (the header row is the contract; changing columns is a coordinated
change in both repos).

Every bundle carries `BUILDINFO`: chezmoi commit (plus `-dirty`), wrapper
commit, profile, build date. `input_stamp` hashes the chezmoi tree's
`home/` and `apps/` plus the wrapper's `portable/`, so a change on either
side changes `VERSION` and `zssh` pushes the new bundle.

`builder.sh run` mounts the wrapper at `/src` and `CHEZMOI_SRC` at
`/chezmoi`, and sets `CHEZMOI_SRC=/chezmoi` inside the container.

## 3. The manifest: `apps/apps.tsv`

One row per installed binary, tab/space-separated, `-` for none, `#`
comments, one header row.

```
# name     tier     bundle  apt         pacman         dnf             brew            release              file   assets                    build
curl       core     -       curl        curl           curl            curl            -                    -      -                         -
eza        core     y       eza         eza            eza             eza             eza-community/eza    eza    musl,tar.gz|gnu,tar.gz    crate:eza
rg         core     y       ripgrep     ripgrep        ripgrep         ripgrep         BurntSushi/ripgrep   rg     musl|gnu                  crate:ripgrep:rg
atuin      core     y       atuin       atuin          atuin           atuin           atuinsh/atuin        atuin  musl,^server|gnu,^server  -
tmux       extra    y       tmux        tmux           tmux            tmux            -                    -      -                         cross:tmux
firacode   desktop  -       fonts-firacode ttf-fira-code fira-code-fonts font-fira-code -                -      -                         -
```

| Column | Meaning |
|---|---|
| `name` | binary name as installed |
| `tier` | `core` / `extra` / `desktop` for `install-apps.sh`; `-` = bundle only |
| `bundle` | `y` = goes into portable bundles |
| `apt` `pacman` `dnf` `brew` | package name, or `-` |
| `release` `file` `assets` | eget source: GitHub repo, `--file` glob, `\|`-separated asset alternatives (tools.tsv semantics) |
| `build` | `crate:CRATE[:BIN][:ARGS]`, `go:MODULE[//SUBPKG]`, `cross:NAME`, or `-` (use the release) |

Consumers:

- `install-apps.sh`: rows with a tier; package first, then `release` via
  `fetch_release` for the host arch; `--build cargo` rebuilds `crate:` rows
  natively (replaces the old `cargo` column).
- `build-tools.sh`: `bundle=y` rows; `build` column for profile builds,
  `release` columns as fallback (replaces `tools.tsv`'s `repo`/`source`).
- A `build` of `-` means the lock's source is `release`, matching today's
  lock format.

`apps/lib.sh` (sourced by both repos; no python/yq, runs on bare hosts):
`apps_rows [--tier T] [--bundle]`, `apps_field ROW COLUMN` (by header name,
never by position), plus `fetch_release` and `elf_arch` moved from
`scripts/portable/lib.sh`, so "download a release for an arch" has one
implementation.

Locks move from `scripts/portable/locks/` to `apps/locks/`, format
unchanged (`name source version`). `qos-orin.lock` (currently untracked) is
committed. Only the wrapper reads locks; host installs keep tracking
packages and latest releases.

Merging the rows: union of both tables by binary name. Where both define
an eget spec, the tools.tsv form wins (it has arch fallbacks); where only
install-apps has one (e.g. `starship`, `nushell`), it is converted to
`release`/`file`/`assets`.

## 4. Thin `zssh` (chezmoi dotfile)

`zssh [--rebuild] [--refresh] [--profile P] [ssh options] host`, deploy
logic (probe, upload, `setup.sh`, `enter`) unchanged. Only how it gets a
bundle changes, first match wins:

1. `$ZSSH_DEPLOY`: a wrapper checkout; runs `$ZSSH_DEPLOY/portable/build.sh`
   with `CHEZMOI_SRC` = chezmoi's source top level.
2. `~/.local/share/chezmoi-deploy`: same, from a chezmoi `git-repo`
   external that only desktop machines get (`.chezmoiexternal.toml.tmpl`,
   `refreshPeriod = "168h"`).
3. Published bundle: download `zsh-portable-<profile>.tar.gz`, its
   `.version` and `SHA256SUMS` from the wrapper's `bundles` GitHub release
   into `~/.cache/zsh-portable/published/`, verify, use. Only `x86_64-v3` is
   published there; other hosts fail with "no published bundle for
   <arch>; set ZSSH_DEPLOY to a chezmoi-deploy checkout".

Host to build target: `--profile P` if given, else `--arch $(uname -m)` as
today. Published lookup maps `x86_64` to `x86_64-v3`.

## 5. CI

No cross-repo secrets.

**chezmoi `.github/workflows/nightly.yml`** (schedule + manual): calls
`JordanBradshaw/chezmoi-deploy/.github/workflows/resolve.yml@main` with
`profile: x86_64-v3` and `permissions: contents: write, pull-requests:
write`. The reusable workflow runs in chezmoi's context: it checks out
chezmoi (default) and the wrapper (public), runs `build-tools.sh --profile
x86_64-v3 --resolve` in `ghcr.io/jordanbradshaw/zsh-builder`, and if
`apps/locks/x86_64-v3.lock` changed opens or updates the PR `apps: rolling
update <date>` in chezmoi with the version diff and failed tools listed.

**chezmoi `tests.yml`**: runs chezmoi's tests on PRs, including the lock PRs.

**wrapper `publish.yml`** (push to `main`, nightly schedule, manual with a
`chezmoi_ref` input): checks out chezmoi `main` (or the ref), runs
`build.sh --profile x86_64-v3 --locked`, and skips if `VERSION` equals the
current `bundles` release's. Otherwise it uploads to the rolling release
`bundles` (assets replaced) and an immutable `bundle-<date>-<version>`,
with `SHA256SUMS`, `tools.lock` and `BUILDINFO`. Polling chezmoi nightly
replaces a dispatch, so chezmoi needs no token for the wrapper; a merged
lock PR is published by the next nightly or a manual run.

**wrapper `builder-image.yml`**: rebuilds `ghcr.io/jordanbradshaw/zsh-builder`
when `features/src/zsh-builder/` or `features/builder/` change.

**wrapper `features.yml`**: `devcontainers/action` publishes features to
`ghcr.io/jordanbradshaw/chezmoi-deploy/<id>` when a
`devcontainer-feature.json` version changes.

**wrapper `tests.yml`**: wrapper tests against `tests/fixtures/chezmoi` and
against a fresh chezmoi `main` checkout.

The work-GitLab `qos-orin` jobs (phase 4 of the rolling-bundles spec) use
the same entry points and are out of scope here.

## 6. Migration (approach A)

### Step 0: clean start

The `rolling-bundles` worktree has uncommitted changes
(`.devcontainer/devcontainer.json`, deleted `remap_mozilla.sh`, untracked
`scripts/portable/locks/qos-orin.lock`). The owner commits or discards them
before work starts. `~/repos/config-chezmoi` holds an uncommitted copy of
an older tree for `JordanBradshaw/chezmoi`; diff it against
`rolling-bundles` and fold anything newer in before it is replaced.

### Step 1: build the seam in zsh-config

On branch `split-seam` off `rolling-bundles`, each a reviewed commit with
tests:

1. `apps/apps.tsv` from both tables; `apps/lib.sh`; locks moved to
   `apps/locks/`; `tests/apps_test.sh` (11 fields per row, known tiers,
   `bundle=y` rows have `release` or `build`, every lock name in the
   manifest, header matches).
2. `install-apps.sh` reads the manifest; `install_apps_test.sh` passes.
3. `build-tools.sh` and `build.sh` take `CHEZMOI_SRC` (default during this
   step: the repo's own top level) and read `apps/`; `tools.tsv` deleted;
   `BUILDINFO` added.
4. `builder.sh` mounts `CHEZMOI_SRC` at `/chezmoi`.
5. Thin `zssh` with the three-step resolution.
6. Decouple tests from history and each other: `zsh_startup_test.sh`'s
   `git show 293e292:…` and `git show $rev:…` become checked-in fixtures
   (filter-repo rewrites hashes); every test file runs from either future
   repo's tree; `tests/fixtures/chezmoi/` (minimal `home/`, `apps/`) for
   wrapper unit tests.
7. Seam test: copy only the future chezmoi paths and only the future
   wrapper paths into two temp dirs, run both suites there. This proves
   neither side reaches into the other except through section 2.

### Step 2: split

From `split-seam`, two fresh clones, `git filter-repo`:

- **chezmoi**: keep `.chezmoiroot`, `.gitignore`, `.devcontainer/`,
  `home/`, `apps/`, `scripts/install-apps.sh`, `scripts/kde/`,
  `scripts/merge-zsh-history.py`, `other/`, `install.sh`, `eget.sh`,
  `tests/` except the wrapper's files, and
  `docs/superpowers/specs/2026-10-24-yupps-zsh-split-design.md`. Push to
  `JordanBradshaw/chezmoi` `main`.
- **chezmoi-deploy**: keep `scripts/portable/` (renamed to `portable/`),
  `features/`, `tests/build_tools_test.sh`, `tests/portable_test.sh`,
  `tests/fixtures/chezmoi/`, and the portable/rolling specs, plans and
  this spec. Fix paths for the rename and update `documentationURL`s. Push
  to `JordanBradshaw/chezmoi-deploy` `main`; check out at
  `~/repos/chezmoi-deploy`, keeping its existing `.opencode/`.
- Add a `.devcontainer/` to the wrapper using the `zsh-builder` feature.
- Run both suites in their new repos, and the wrapper's suite against a
  fresh chezmoi clone.

### Step 3: switch over

- On each machine, `chezmoi init --apply JordanBradshaw/chezmoi`. The
  source dir changes and the target files stay the same. Check with
  `chezmoi diff` before applying.
- `zsh-config`: README pointing to both repos; archive the repo once no
  machine uses it.

### Step 4: CI

Add the workflows in section 5, wrapper first (`builder-image`, `tests`,
`publish`, `resolve`), then chezmoi's `nightly` and `tests`.

## Non-goals

- Implementing the `zsh-config` consumer feature. It is specified in the
  rolling-bundles spec and moves with the wrapper as is.
- The work-GitLab `qos-orin` pipeline.
- Changing what goes into a bundle, or how `zssh` deploys it on the host.

## Risks

- **Interface drift.** A chezmoi change can break wrapper builds unnoticed.
  The wrapper's nightly `publish` and `tests` run against chezmoi `main`,
  so breakage shows up within a day; the header check fails loudly.
- **Rewritten hashes.** filter-repo rewrites commit hashes. Step 1.6
  removes every hash reference in tests, and old hashes stay valid in the
  archived zsh-config repo.
- **Reusable workflow pinned to `@main`.** A wrapper change can break
  chezmoi's nightly. Pin a tag (`@v1`) once the workflow is stable.
