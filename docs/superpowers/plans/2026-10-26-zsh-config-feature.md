# zsh-config devcontainer feature: Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Publish an x86_64 devcontainer feature that installs the zsh setup and release-built tools into the user's home, with chezmoi's manifest choosing the tools per portable target.

**Architecture:** chezmoi's manifest gets a `portable` column (`zssh`/`dev`); chezmoi-deploy's `build.sh` gains `--target`; a new `zsh-config` feature installs the `dev` bundle published by a new `publish.yml`.

**Tech Stack:** bash, chezmoi, eget, docker, GitHub Actions, devcontainers/action.

**Spec:** `docs/superpowers/specs/2026-10-26-zsh-config-feature-design.md` (chezmoi-deploy)

## Global Constraints

- Repos: `~/repos/chezmoi` (Task 1) and `~/repos/chezmoi-deploy` (Tasks 2-4), branch `main`. Do not push; the controller pushes both repos together.
- Manifest columns after Task 1: `name tier portable apt pacman dnf brew release file assets build`. `portable` ∈ `zssh`, `dev`, `zssh,dev`, `-`.
- Deploy tests run as `CHEZMOI_SRC=$HOME/repos/chezmoi bash tests/<x>_test.sh`.
- Known failure, not yours: chezmoi `tests/tmux_test.sh`.
- `docs/` is globally gitignored: `git add -f` for docs files.
- Test files follow the existing style: `test_*` functions, `run_test`, final `N passed, M failed`, non-zero exit on failure.

## Review Focus

1. A `dev` row without a release: `apps_test.sh` fails naming the row.
2. Existing `~/.zshenv` in the base image: kept as `~/.zshenv.pre-zsh-config`, never silently lost.
3. Checksum mismatch or missing `SHA256SUMS`: `install.sh` exits non-zero before touching the home dir.
4. Base image without curl (debian slim): installed by the feature, or a clear error.
5. zssh keeps working: `--target zssh` output name and contents unchanged.

---

### Task 1: `portable` column (chezmoi)

**Files:** `apps/apps.tsv`, `apps/lib.sh`, `tests/apps_test.sh`; delete `apps/locks/x86_64-v3.lock`, `.github/workflows/nightly.yml`.

**Interfaces (produces):** `APPS_COLUMNS=(name tier portable apt pacman dnf brew release file assets build)`; `apps_names --portable T` (row's comma list contains T); `--bundle` removed.

- [ ] Tests first in `apps_test.sh`: rename bundle checks to portable; `test_known_portable_values`; `test_dev_rows_have_release` (Review Focus 1, plus a fixture row proving the message names the row); `test_pipx_rows_not_portable`; `test_lock_names_in_manifest` uses `--portable zssh`; `test_apps_names_filters` covers `--portable dev` (has `lazydocker`, not `tmux`) and `--portable zssh` (has `tmux`); a fixture `zssh,dev` row matches both, a `dev` row not `zssh`. RED.
- [ ] Implement: header `bundle`→`portable`; `y`→`zssh,dev` except `tmux`→`zssh`; update the column docs comment; lib change. GREEN: `bash tests/apps_test.sh`, `bash tests/install_apps_test.sh`.
- [ ] `git grep -n 'bundle=y\|--bundle' -- ':!docs'` → nothing outside comments that mean the portable bundle in prose.
- [ ] Commit `feat(apps): portable column selects zssh and dev bundles; drop x86_64 lock and nightly`.

### Task 2: `build.sh --target` (chezmoi-deploy)

**Files:** `portable/build.sh`, `portable/build-tools.sh`, `tests/portable_test.sh`, `tests/build_tools_test.sh`; delete `.github/workflows/resolve.yml`.

**Interfaces:** `build.sh --target zssh|dev` (default `zssh`); bundle `zsh-portable-ARCH.tar.gz` (zssh) / `zsh-portable-dev-ARCH.tar.gz` (dev); `input_stamp` and `build_info` take the target (`build_info` prints a `target T` line); `fetch_tools ARCH DEST TARGET` uses `apps_names --portable TARGET`; `build-tools.sh` uses `--portable zssh`.

- [ ] Tests: fixture manifests switch to the `portable` column; `test_target_selects_rows` (dev excludes a zssh-only row); `test_bundle_names_per_target`; `test_stamp_includes_target`; `test_build_info_lines` gains `target`; unknown `--target` exits 2 with usage; build-tools ignores a `dev`-only row. RED, implement, GREEN for both files and `tests/lock_diff_test.sh`.
- [ ] Real check: `CHEZMOI_SRC=~/repos/chezmoi portable/build.sh --target dev --arch x86_64 --force`; tar lists `bin/lazydocker`, no `bin/tmux`; BUILDINFO has `target dev`.
- [ ] Update header comments; delete `resolve.yml`. Commit `feat(build): --target zssh|dev from the manifest's portable column`.

### Task 3: the `zsh-config` feature (chezmoi-deploy)

**Files:** create `features/src/zsh-config/devcontainer-feature.json`, `features/src/zsh-config/install.sh`, `tests/feature_test.sh`.

**Interfaces:** spec section 3 exactly (options, paths, messages, mount, VS Code settings).

- [ ] `feature_test.sh` unit tests (no docker): JSON valid with the three options and the mount; `bash -n install.sh`; `test_rejects_non_x86` (stub `uname` printing `aarch64` on PATH; the arch check runs before anything needing root, so install.sh exits non-zero with the spec message). Checksum and install behaviour need root, so they are e2e-only (next step). RED, implement, GREEN.
- [ ] `FEATURE_E2E=1 FEATURE_BUNDLE=<path>` mode: for `ubuntu:24.04` and `debian:12`: create user `dev` with an existing `~/.zshenv`, copy the feature + bundle + `SHA256SUMS` in, run `install.sh` as root with `_REMOTE_USER=dev _REMOTE_USER_HOME=/home/dev BUNDLEURL=file:///bundle/zsh-portable-dev-x86_64.tar.gz`, `docker commit`, then in the committed image with `--network none` as `dev`: `~/.local/bin/lsd --version` runs; `zsh -i -c 'print -r -- $ZSH_PORTABLE; echo ok'` exits 0 and prints `ok`; `getent passwd dev` shell is `/usr/local/bin/zsh`; `~/.zshenv.pre-zsh-config` exists (Review Focus 2); after `zsh -i -c 'print -s hi; fc -W'`, `/var/lib/zsh-config/zsh/history` exists. A corrupted sum makes install.sh fail with no `~/.local/bin/zsh` (Review Focus 3). debian:12 starts without curl (Review Focus 4).
- [ ] Run e2e with the Task 2 bundle (generate `SHA256SUMS` with `sha256sum`). All pass.
- [ ] Commit `feat(features): zsh-config devcontainer feature`.

### Task 4: publishing (chezmoi-deploy)

**Files:** create `.github/workflows/publish.yml`; modify `.github/workflows/tests.yml` (add `bash tests/feature_test.sh`).

- [ ] `publish.yml` per spec section 4: `permissions: contents: write`; `concurrency: publish`; tags `bundles` (rolling: `gh release create bundles --prerelease` if missing, `gh release upload --clobber`) and `bundle-dev-<YYYY-MM-DD>-<version>` (`gh release create`); previous version from `gh release download bundles -p '*.version'` (missing release = publish); feature e2e gate with `FEATURE_E2E=1`.
- [ ] actionlint both workflows (`/tmp/opencode/actionlint`, or `eget rhysd/actionlint --to /tmp/opencode/actionlint`): no output.
- [ ] Commit `ci: publish the dev bundle; feature tests`.
