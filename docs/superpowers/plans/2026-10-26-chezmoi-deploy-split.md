# Split zsh-config into chezmoi and chezmoi-deploy: Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn the `rolling-bundles` branch of zsh-config into two repos: `~/repos/chezmoi` (dotfiles, one app manifest, version locks) and `~/repos/chezmoi-deploy` (portable builds, features, CI). They connect only through a `CHEZMOI_SRC` checkout.

**Architecture:** First build the seam inside zsh-config on branch `split-seam`, with each side tested there. A seam check copies each side's paths into its own tree and runs that side's tests alone. Then `git filter-repo` splits history using the same path lists. Switch this machine's chezmoi `sourceDir` over, then add CI.

**Tech Stack:** bash, chezmoi, eget, git-filter-repo, GitHub Actions, devcontainers/action.

**Spec:** `docs/superpowers/specs/2026-10-26-chezmoi-deploy-split-design.md` (read it; this plan argues from it)

## Global Constraints

- Work in `~/repos/zsh-config-rolling` on branch `split-seam` (created from `rolling-bundles`) until Task 9.
- Manifest columns, exact names: `name tier bundle apt pacman dnf brew release file assets build`; `-` means none.
- `build` values: `crate:CRATE[:BIN][:ARGS]`, `go:MODULE[//SUBPKG]`, `cross:NAME`, `-`. A `-` is source `release` in locks.
- Lock format unchanged: `name<TAB>source<TAB>version`, with the existing header line.
- Find the chezmoi tree in this order: `--chezmoi DIR`, then `$CHEZMOI_SRC`, then `git -C "$(chezmoi source-path)" rev-parse --show-toplevel`.
- `apps/lib.sh` must run on bare hosts: bash plus coreutils only. No python, yq or jq.
- Test files follow the existing pattern: `test_*` functions, `run_test`, a final `N passed, M failed` line, and a non-zero exit on failure.
- Never push, create GitHub repos or change GitHub settings without the owner's go-ahead in chat (Tasks 9, 11, 12).
- `docs/` is in the owner's global gitignore; add files there with `git add -f`.
- Out of scope (the spec defers them to rolling-bundles phase 2): `publish.yml`, `zssh --profile`, published-bundle download.

## Review Focus

1. **Malformed manifest row** (missing column, duplicate name, unknown header) on a bare host: `install-apps.sh` stops and names the file and line. It must not install with shifted columns. → Task 2 tests.
2. **`CHEZMOI_SRC` points at a tree without `apps/`.** This machine's current `sourceDir` is the old zsh-config `config` branch. Expected: `build.sh` and `build-tools.sh` fail with `no apps/apps.tsv in DIR (set CHEZMOI_SRC or --chezmoi to a chezmoi checkout)`. → Task 2 test (`resolve_chezmoi_src`).
3. **Rebuild with unchanged content** (only `BUILDINFO`'s commit or date differs): `VERSION` is unchanged, so `zssh` does not re-upload. → Task 5 test.
4. **`zssh` with no wrapper checkout anywhere:** exits non-zero with the exact message from spec §4 and opens no ssh session. → Task 7 test.
5. **A tracked file in neither split list:** `split/check.sh` fails and lists the file, so nothing is lost silently in filter-repo. → Task 8 test.

---

### Task 0: Branch, tools, fold in leftovers

**Files:** none tracked except `apps/locks/qos-orin.lock` in Task 2. This task only prepares.

- [ ] **Step 1:** Run `git -C ~/repos/zsh-config-rolling switch -c split-seam`.
- [ ] **Step 2:** Run `pipx install git-filter-repo`, then `git filter-repo --version`. Expected: a version hash.
- [ ] **Step 3:** Run `git -C ~/repos/zsh-config log --oneline rolling-bundles..config`. Expected: empty. If it is not empty, `git merge config` into `split-seam` and resolve conflicts.
- [ ] **Step 4:** Run `diff -rq --exclude=.git ~/repos/config-chezmoi ~/repos/zsh-config-rolling`. Note that `config-chezmoi` uses `chezmoi/home` where the worktree uses `home`. For each file that differs, compare mtimes and contents. Report anything newer in `config-chezmoi` to the owner, and fold it in only on their say-so. Expected outcome: only `scripts/portable/locks/qos-orin.lock` is new.
- [ ] **Step 5:** Run `cp ~/repos/config-chezmoi/scripts/portable/locks/qos-orin.lock /tmp/opencode/qos-orin.lock`. Task 2 commits it.

### Task 1: Rename `scripts/portable/` → `portable/`

**Files:**
- Move: `scripts/portable/` → `portable/`
- Modify: every hit of `git grep -l scripts/portable` except files in `docs/`: `portable/build.sh`, `portable/build-tools.sh`, `portable/builder.sh`, `features/builder/x86_64.Dockerfile`, `home/dot_local/bin/executable_zssh`, `tests/build_tools_test.sh`, `tests/portable_test.sh`
- Modify: `portable/builder.sh:19`. `REPO` becomes the parent of `portable/` (one `..`, not two).

- [ ] **Step 1:** Run `git mv scripts/portable portable` and fix every reference listed above.
- [ ] **Step 2:** Run `bash tests/build_tools_test.sh; bash tests/portable_test.sh`. Expected: same pass counts as before the move, 0 failed.
- [ ] **Step 3:** Run `git grep -n 'scripts/portable' -- ':!docs'`. Expected: no output.
- [ ] **Step 4:** Commit: `refactor(portable): move scripts/portable to portable/`.

### Task 2: The manifest, `apps/lib.sh`, locks, and the seam shim

**Files:**
- Create: `apps/apps.tsv`, `apps/lib.sh`, `tests/apps_test.sh`
- Move: `portable/locks/*.lock` → `apps/locks/`; add `apps/locks/qos-orin.lock` from Task 0
- Modify: `portable/lib.sh`. Its current content moves to `apps/lib.sh`. It becomes the shim below.
- Move tests: `test_every_tools_row_has_valid_source`, `test_cross_rows_keep_cross_repo`, `test_known_sources` from `tests/build_tools_test.sh` → `tests/apps_test.sh`, rewritten for the manifest. `test_build_sh_ignores_source_column` is deleted.

**Interfaces (produces):**
- `apps/lib.sh`:
  - `APPS_COLUMNS=(name tier bundle apt pacman dnf brew release file assets build)`
  - `APPS_FILE`, defaulting to the `apps.tsv` next to `lib.sh`
  - `apps_load [FILE]`: returns 0, or prints `FILE:LINE: …` to stderr and returns 1. It fills `APPS_NAMES` (array, file order) and `APP` (associative array, key `NAME,COLUMN`).
  - `apps_names [--tier T | --bundle]`: prints names, one per line, in file order.
  - `app NAME COLUMN`: prints the value.
  - Moved unchanged from `portable/lib.sh`: `ASSET_EXCLUDES`, `normalize_arch`, `eget_system`, `asset_candidates`, `asset_args`, `elf_arch`, `load_github_token`, `fetch_release`.
- `portable/lib.sh`:
  - `resolve_chezmoi_src [DIR]`: sets and exports `CHEZMOI_SRC`, using the order in Global Constraints. It fails with Review Focus #2's message when `$CHEZMOI_SRC/apps/apps.tsv` is missing.
  - After `resolve_chezmoi_src`, `portable/lib.sh` sources `$CHEZMOI_SRC/apps/lib.sh`.
  - `build.sh` and `build-tools.sh` call `resolve_chezmoi_src` (no argument) right after sourcing `portable/lib.sh` at top level. Tests source these scripts for their functions without running `main`, so they export `CHEZMOI_SRC` first.
  - `main`'s `--chezmoi DIR` calls `resolve_chezmoi_src DIR` again, which re-sources `apps/lib.sh` from DIR.

**Manifest contents.** Union of `scripts/install-apps.sh`'s `APPS` and `tools.tsv`, keyed by binary name:
- install-apps names map to binaries: `ripgrep`→`rg`, `tailspin`→`tspin`, `nushell`→`nu`.
- A row present in both tables keeps the tools.tsv `release/file/assets` and gets `bundle=y`.
- install-apps-only eget specs `owner/repo:bin:a,b` become `release=owner/repo file=bin assets=a,b`.
- `build` comes from tools.tsv's `source`, with `release` written as `-`. For install-apps-only rows it comes from the old `cargo` column as `crate:…`.
- tools.tsv-only rows get `tier=-`.
- `tmux` keeps `file=tmux`.
- `firacode` keeps `name=firacode`.

- [ ] **Step 1: Write failing tests** in `tests/apps_test.sh`. Each test sources `apps/lib.sh` in a subshell. Fixtures go in a temp file via `APPS_FILE`.
  - `test_real_manifest_loads`: `apps_load` on `apps/apps.tsv` returns 0.
  - `test_header_must_name_every_column`: a header missing `build` fails, and stderr matches `header`.
  - `test_short_row_names_line`: a 10-field row on line 3 fails with stderr `…:3: 10 fields, expected 11`.
  - `test_duplicate_name_fails`: two `rg` rows fail, and stderr matches `duplicate rg`.
  - `test_columns_read_by_name`: a fixture with `build` and `name` swapped in the header still gives `app rg build` = `crate:ripgrep:rg`.
  - `test_known_tiers`: every real row has a tier in `core extra desktop -`.
  - `test_bundle_rows_have_a_source`: every real `bundle=y` row has `release`≠`-` or `build`≠`-`.
  - `test_known_build_sources`: every real `build` matches `^(crate:|go:|cross:|-$)`.
  - `test_cross_rows_have_no_release`: `cross:` rows have `release=-`.
  - `test_lock_names_in_manifest`: every name in `apps/locks/*.lock` is a `bundle=y` row, and its lock source equals the row's `build`, mapping `-`→`release`.
  - `test_merged_rows`: exact values for `app rg apt`=`ripgrep`, `app tspin tier`=`extra`, `app nu release`=`nushell/nushell`, `app atuin build`=`-`, `app lazydocker tier`=`-`, `app firacode bundle`=`-`.
  - `test_apps_names_filters`: `apps_names --tier core` includes `curl` and excludes `lazydocker`. `apps_names --bundle` includes `lazydocker` and excludes `curl`.
  - `test_resolve_chezmoi_src_order`: in a subshell sourcing `portable/lib.sh`, an explicit DIR beats `$CHEZMOI_SRC`, and `$CHEZMOI_SRC` beats a stub `chezmoi source-path` on PATH.
  - `test_resolve_chezmoi_src_rejects_tree_without_apps`: Review Focus #2. The exact message is in `portable/lib.sh` above.
- [ ] **Step 2:** Run `bash tests/apps_test.sh`. Expected: FAIL (no `apps/lib.sh`).
- [ ] **Step 3:** Implement `apps/lib.sh`, `apps/apps.tsv` and the shim. Move the locks with `git mv` and add `qos-orin.lock`. Point `tests/portable_test.sh` and `tests/build_tools_test.sh` at the moved helpers: they source `portable/lib.sh` with `CHEZMOI_SRC=$REPO_DIR` exported at the top.
- [ ] **Step 4:** Run `bash tests/apps_test.sh; bash tests/portable_test.sh`. Expected: 0 failed. `build_tools_test.sh` may still fail until Task 4.
- [ ] **Step 5:** Commit: `feat(apps): one app manifest, shared lib, locks under apps/`.

### Task 3: `install-apps.sh` reads the manifest

**Files:**
- Modify: `scripts/install-apps.sh`. Remove `APPS` and its own `load_github_token`. Source `"$(dirname "$0")/../apps/lib.sh"`, then call `apps_load` and exit 1 on failure.
- Modify: `home/.chezmoiscripts/run_onchange_after_10-install-apps.sh.tmpl`. Add hash comment lines for `apps/apps.tsv` and `apps/lib.sh`, in the same form as the existing `install-apps.sh hash:` line.
- Test: `tests/install_apps_test.sh`

**Interfaces:**
- Consumes: `apps_load`, `apps_names --tier T`, `app`, `fetch_release`, `normalize_arch`, `load_github_token` (Task 2).
- Produces:
  - `install_release NAME`: skips when `command -v NAME` succeeds. Otherwise it runs `ensure_eget`, then `run fetch_release NAME RELEASE FILE ASSETS "$(normalize_arch "$(uname -m)")" "$HOME/.local/bin/NAME"`.
  - `install_cargo "CRATE[:BIN[:ARGS]]"`: comma-separated ARGS are passed to `cargo install`.
  - The package column comes from the pm name (`apt pacman dnf brew`) via `app`. The crate list is the `build` values starting `crate:`, with the prefix stripped.

- [ ] **Step 1: Update tests first.**
  - `stub_eget_logging` (and the curl-installed eget stub) also writes a fake x86_64 ELF to the `--to` path. Copy `fake_elf` from `tests/portable_test.sh`. A `uname` stub prints `x86_64`.
  - Every `assert_call "eget OWNER/REPO --file BIN … --to $HOME/.local/bin"` becomes `assert_call_matches "^eget .*--file BIN .*--to $HOME/.local/bin/BIN .*OWNER/REPO$"`.
  - DRY_RUN expectations become `+ fetch_release BIN OWNER/REPO …`.
  - `CORE_APT` and the tier lists keep the same package names.
  - New test `test_release_for_wrong_arch_is_reported`: the eget stub writes an aarch64 ELF, so the run exits 1 and stderr names the tool in `Failed to install:`.
  - New test `test_run_onchange_hashes_manifest`: the rendered script contains the `apps.tsv` hash line, and the hash changes when a temp copy of the manifest changes.
  - New test `test_cargo_args_passed`: a manifest fixture row `build=crate:x:x:--no-default-features,--features,rustls` puts those args on the cargo call.
- [ ] **Step 2:** Run `bash tests/install_apps_test.sh`. Expected: FAIL on the new and updated tests.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Run `bash tests/install_apps_test.sh`. Expected: 0 failed.
- [ ] **Step 5:** Commit: `feat(install-apps): read apps/apps.tsv; releases via fetch_release`.

### Task 4: `build-tools.sh` reads the manifest and chezmoi's locks

**Files:**
- Modify: `portable/build-tools.sh`. Add a `--chezmoi DIR` flag. `TOOLS_FILE` becomes `APPS_FILE` (default `$CHEZMOI_SRC/apps/apps.tsv`). The `LOCKS_DIR` default becomes `$CHEZMOI_SRC/apps/locks`. Update the header comment.
- Test: `tests/build_tools_test.sh`. `use_tools` writes manifest-format fixtures with the header row and exports `APPS_FILE`.

**Interfaces:**
- Consumes: `resolve_chezmoi_src`, `apps_load`, `apps_names --bundle`, `app` (Task 2).
- Produces: `load_tools` fills `REPOS=release`, `FILES=file`, `SPECS=assets`, and `SOURCES=build` (`-`→`release`) for `bundle=y` rows. Everything downstream is unchanged. Cache keys for `cross:` rows change once (their `REPOS` was `cross:NAME`); accept one rebuild.

- [ ] **Step 1:** Convert the fixtures and add:
  - `test_chezmoi_flag_sets_locks_dir`: `--chezmoi $SANDBOX/cz` reads `$SANDBOX/cz/apps/locks/x86_64-v3.lock`.
  - `test_non_bundle_rows_ignored`: a fixture row with `bundle=-` never appears in `tools.lock`.
- [ ] **Step 2:** Run `bash tests/build_tools_test.sh`. Expected: FAIL.
- [ ] **Step 3:** Implement and delete `portable/tools.tsv`.
- [ ] **Step 4:** Run `bash tests/build_tools_test.sh; bash tests/apps_test.sh`. Expected: 0 failed. The in-container check is in Task 6, which adds the `/chezmoi` mount.
- [ ] **Step 5:** Commit: `feat(build-tools): read chezmoi's manifest and locks`.

### Task 5: `build.sh` reads chezmoi via `CHEZMOI_SRC`; `BUILDINFO`

**Files:**
- Modify: `portable/build.sh`:
  - Add a `--chezmoi DIR` flag.
  - `REPO` becomes `CHEZMOI_SRC` for every chezmoi call. `DEPLOY_DIR` is the parent of `SCRIPT_DIR`.
  - `fetch_tools` iterates `apps_names --bundle`. It builds `cross:` rows with the cross script, fetches rows with a `release` via `fetch_release`, and skips other rows with the existing warning.
  - Update the header comment.
- Test: `tests/portable_test.sh`

**Interfaces:**
- `input_stamp CHEZMOI DEPLOY ARCH [YUPPS_DIR]`: hashes `git ls-files -co` of `home apps` in CHEZMOI and of `portable` in DEPLOY, with the same deleted-file handling as today.
- `build_info CHEZMOI DEPLOY ARCH`: prints four lines, `chezmoi SHA[-dirty]`, `deploy SHA[-dirty]`, `arch ARCH`, `built YYYY-MM-DDTHH:MM:SSZ`.
  - Outside a git repo the SHA is `unknown`.
  - `-dirty` means `git status --porcelain` shows changes in `home apps` (chezmoi) or `portable` (deploy).
- `main`: writes `$app/BUILDINFO` after `VERSION` is computed, so `BUILDINFO` is not part of `tree_hash`.

- [ ] **Step 1: Tests.**
  - Update `test_input_stamp_handles_deleted_tracked_files` for two repos.
  - `test_input_stamp_sees_both_sides`: a change in CHEZMOI `apps/` changes the stamp, a change in DEPLOY `portable/` changes it, and a change in CHEZMOI `scripts/` does not.
  - `test_build_info_lines`: with two temp git repos, the output matches the four patterns, and `-dirty` appears after editing a file under `home/`.
  - `test_buildinfo_not_in_version` (Review Focus #3): `tree_hash` of an app dir is unchanged after adding `BUILDINFO` to a copy of it. Assert that `main` writes `BUILDINFO` after `tree_hash`. To test this without network, source `build.sh` and run `main` with `fetch_zsh`, `fetch_tools`, `fetch_plugins`, `fetch_git_externals`, `export_dotfiles` and `check_secrets` overridden by stubs that create fixed files, then build twice. Expected: the same `.version`, with the `built` lines differing.
  - `test_fetch_tools_uses_manifest`: a fixture manifest with one `cross:` row and one `bundle=-` row calls the cross script once and never touches the other row.
- [ ] **Step 2:** Run `bash tests/portable_test.sh`. Expected: FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Run `bash tests/portable_test.sh`. Expected: 0 failed.
- [ ] **Step 5:** Run `CHEZMOI_SRC=$PWD portable/build.sh --arch x86_64 --force`, then `tar -xOzf <bundle> ./BUILDINFO`. Expected: four lines, with `chezmoi` and `deploy` being the same SHA (one repo for now).
- [ ] **Step 6:** Commit: `feat(build): read chezmoi via CHEZMOI_SRC; BUILDINFO in bundles`.

### Task 6: `builder.sh` mounts the chezmoi tree

**Files:**
- Modify: `portable/builder.sh`. `run` calls `resolve_chezmoi_src` and adds `-v "$CHEZMOI_SRC:/chezmoi" -e CHEZMOI_SRC=/chezmoi`. Update the header comment.
- Test: `tests/build_tools_test.sh`. Extend the existing docker-run-args test.

- [ ] **Step 1:** Add `-v $SANDBOX/cz:/chezmoi` and `-e CHEZMOI_SRC=/chezmoi` to the expected args, with `CHEZMOI_SRC=$SANDBOX/cz` set (it contains `apps/apps.tsv`).
- [ ] **Step 2:** Run the test. Expected: FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Run `bash tests/build_tools_test.sh`. Expected: 0 failed.
- [ ] **Step 5:** Run `portable/builder.sh image`, then `CHEZMOI_SRC=$PWD portable/builder.sh run portable/build-tools.sh --profile x86_64-v3 --locked --only rg,fzf --out "${XDG_CACHE_HOME:-$HOME/.cache}/zsh-portable/bt"`. The output dir must be under the cache mount to be visible on the host. Expected: that dir's `tools.lock` lists `rg` and `fzf` with the versions in `apps/locks/x86_64-v3.lock`.
- [ ] **Step 6:** Commit: `feat(builder): mount CHEZMOI_SRC at /chezmoi`.

### Task 7: Thin `zssh`

**Files:**
- Modify: `home/dot_local/bin/executable_zssh` (spec §4). Remove `ZSSH_REPO` and update the usage text.
- Create: `tests/zssh_test.sh`. Move the `stub_remote`, `run_zssh` and `test_zssh_*` tests and their helpers out of `tests/portable_test.sh`. The header comment of `portable_test.sh` no longer mentions zssh.

**Interfaces:** builder resolution order:
1. `ZSSH_BUILDER`
2. `$ZSSH_DEPLOY/portable/build.sh`
3. `${XDG_DATA_HOME:-$HOME/.local/share}/chezmoi-deploy/portable/build.sh`
4. Fail with exactly `zssh: no chezmoi-deploy checkout; set ZSSH_DEPLOY or run chezmoi apply on a desktop`, exit 1.

`CHEZMOI_SRC` is exported. If it is unset, it becomes `git -C "$(chezmoi source-path)" rev-parse --show-toplevel`; if that fails, exit 1 with `zssh: set CHEZMOI_SRC to your chezmoi checkout`.

- [ ] **Step 1: Tests in `tests/zssh_test.sh`.**
  - All moved tests pass unchanged, using `ZSSH_BUILDER`.
  - `test_zssh_uses_zssh_deploy`: stub `$SANDBOX/deploy/portable/build.sh` (the existing stub builder), with `ZSSH_BUILDER` unset. Expected: `build --arch aarch64` in the log.
  - `test_zssh_falls_back_to_chezmoi_external`: same stub at `$XDG_DATA_HOME/chezmoi-deploy/portable/build.sh`, with `ZSSH_DEPLOY` unset.
  - `test_zssh_without_wrapper_fails_clearly` (Review Focus #4): exit 1, the exact message, and `refute_call_matches "^ssh "`.
  - `test_zssh_exports_chezmoi_src`: the stub builder logs `CHEZMOI_SRC=$CHEZMOI_SRC`. With `CHEZMOI_SRC` unset and a stub `chezmoi` printing `$SANDBOX/cz/home` (a git repo), the log shows `$SANDBOX/cz`.
- [ ] **Step 2:** Run `bash tests/zssh_test.sh`. Expected: the new tests FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Run `bash tests/zssh_test.sh; bash tests/portable_test.sh`. Expected: 0 failed in both.
- [ ] **Step 5:** Commit: `feat(zssh): find the builder in a chezmoi-deploy checkout`.

### Task 8: Decouple tests from history; the seam check

**Files:**
- Create: `tests/fixtures/legacy/zshenv-b2f284e`, `tests/fixtures/legacy/zshenv-b0d2f72`, `tests/fixtures/legacy/zshrc-293e292`. Take them from `git show REV:PATH` as used today.
- Modify: `tests/zsh_startup_test.sh:155-158,329`. Read the fixtures instead of `git show`.
- Create: `split/chezmoi.paths`, `split/deploy.paths`, `split/check.sh`, `split/check_test.sh`

**Interfaces:**
- `split/*.paths`: one path per line, `git filter-repo --paths-from-file` syntax (plain prefixes, no comments). Paths that are absent at HEAD are history-only.
- `chezmoi.paths`: `.chezmoiroot .gitignore .devcontainer/ home/ apps/ scripts/install-apps.sh scripts/kde/ scripts/merge-zsh-history.py scripts/portable/tools.tsv scripts/portable/locks/ other/ install.sh eget.sh remap_mozilla.sh tests/apps_test.sh tests/install_apps_test.sh tests/zssh_test.sh tests/fonts_test.sh tests/tmux_test.sh tests/history_merge_test.sh tests/zsh_startup_test.sh tests/zsh/ tests/fixtures/legacy/ docs/superpowers/specs/2026-10-24-yupps-zsh-split-design.md`
- `deploy.paths`: `portable/ scripts/portable/ features/ tests/build_tools_test.sh tests/portable_test.sh docs/superpowers/specs/2026-10-20-portable-zsh-bundle-design.md docs/superpowers/specs/2026-10-26-rolling-bundles-and-devcontainer-feature-design.md docs/superpowers/specs/2026-10-26-chezmoi-deploy-split-design.md docs/superpowers/plans/2026-10-26-phase1-builder-and-build-tools.md docs/superpowers/plans/2026-10-26-chezmoi-deploy-split.md`
- `split/check.sh [--no-tests]`:
  1. It fails, listing the files, if any file in `git ls-files` (except under `split/`) matches neither list.
  2. It fails, listing the files, if any matches both lists, except history-only paths.
  3. It exports each list's HEAD paths with `git archive HEAD -- PATHS | tar -x` into `/tmp/opencode/seam/{chezmoi,deploy}`, then runs `git init` and commits each tree.
  4. It runs the chezmoi suites (every `tests/*_test.sh` in the chezmoi tree, plus `tests/zsh/run.sh`) there. It runs the deploy suites there with `CHEZMOI_SRC=/tmp/opencode/seam/chezmoi`.
  5. Exits non-zero if anything failed.

- [ ] **Step 1:** Write the legacy fixtures and switch `zsh_startup_test.sh` to them. Run `bash tests/zsh_startup_test.sh`. Expected: same pass count, 0 failed. Run `git grep -nE '293e292|b2f284e|b0d2f72|git -C "\$REPO_DIR" show' tests/`. Expected: no output.
- [ ] **Step 2:** Write `split/check_test.sh`. In a temp git repo with its own tiny `split/*.paths`:
  - `test_unlisted_file_fails` (Review Focus #5): output names the file.
  - `test_file_in_both_lists_fails`
  - `test_history_only_path_allowed`
  - `test_trees_contain_only_their_paths`, run with `--no-tests`.
- [ ] **Step 3:** Run `bash split/check_test.sh`. Expected: FAIL.
- [ ] **Step 4:** Implement `split/check.sh` and the two path lists.
- [ ] **Step 5:** Run `bash split/check_test.sh`, then `bash split/check.sh`. Expected: 0 failed, and every suite passes in both seam trees.
- [ ] **Step 6:** Commit: `test: history-free fixtures; split path lists and seam check`.

### Task 9: Split (needs owner go-ahead for remote steps)

**Files:** none in zsh-config. This task creates the two repos.

- [ ] **Step 1:** Run `bash split/check.sh`. Expected: pass. Do not continue otherwise.
- [ ] **Step 2: chezmoi.**
  1. `git clone --no-local --single-branch --branch split-seam ~/repos/zsh-config /tmp/opencode/split-chezmoi`
  2. In it, run `git filter-repo --force --paths-from-file ~/repos/zsh-config-rolling/split/chezmoi.paths` and `git branch -m main`.
  3. `git clone /tmp/opencode/split-chezmoi ~/repos/chezmoi`. The directory is empty, so the clone works.
  4. `git -C ~/repos/chezmoi remote set-url origin git@github.com:JordanBradshaw/chezmoi.git`
- [ ] **Step 3: chezmoi-deploy.**
  1. Clone and filter the same way with `deploy.paths` into `/tmp/opencode/split-deploy`.
  2. In `~/repos/chezmoi-deploy`: `git init -b main`, `git fetch /tmp/opencode/split-deploy main`, `git reset --hard FETCH_HEAD`, `git remote add origin git@github.com:JordanBradshaw/chezmoi-deploy.git`.
  3. Add `.gitignore` (`.opencode/`).
  4. Add `.devcontainer/devcontainer.json`: image `mcr.microsoft.com/devcontainers/base:ubuntu`, feature `./features/src/zsh-builder`.
  5. Update `documentationURL` in `features/src/*/devcontainer-feature.json` to `https://github.com/JordanBradshaw/chezmoi-deploy/tree/main/features/src/<id>`.
  6. Commit: `chore: standalone chezmoi-deploy repo`.
- [ ] **Step 4:** Run `git -C ~/repos/chezmoi log --oneline -- home | wc -l` and the same in `zsh-config-rolling`. Expected: equal counts. Run `git -C ~/repos/chezmoi-deploy log --oneline -- portable scripts/portable | head`. Expected: Task 1–8 commits and the phase-1 history.
- [ ] **Step 5:**
  - In `~/repos/chezmoi`, run every `tests/*_test.sh` and `tests/zsh/run.sh`.
  - In `~/repos/chezmoi-deploy`, run `CHEZMOI_SRC=~/repos/chezmoi bash tests/build_tools_test.sh` and `… tests/portable_test.sh`.
  - Expected: all 0 failed.
- [ ] **Step 6: Ask the owner before continuing.**
  1. `gh repo create JordanBradshaw/chezmoi-deploy --public`
  2. `git -C ~/repos/chezmoi push -u origin main`
  3. `git -C ~/repos/chezmoi-deploy push -u origin main`
  4. Check with `git ls-remote` on both. Expected: `refs/heads/main` at the local HEAD.

### Task 10: Switch over

**Files:**
- Modify (in `~/repos/chezmoi`): `home/.chezmoiexternal.toml.tmpl`. Inside a `{{ if eq .machine "desktop" }}` block, add an entry `[".local/share/chezmoi-deploy"]` with `type = "git-repo"`, `url = "https://github.com/JordanBradshaw/chezmoi-deploy.git"` and `refreshPeriod = "168h"`.
- Modify (in `~/repos/chezmoi`): `.devcontainer/devcontainer.json`. `postCreateCommand` clones `https://github.com/JordanBradshaw/chezmoi.git` (no `--branch config`) into `$HOME/dotfiles` and runs `install.sh`.
- Test (in `~/repos/chezmoi`): `tests/zssh_test.sh`.

- [ ] **Step 1:** Add `test_deploy_external_desktop_only`: rendering the externals template with `machine = "desktop"` contains `[".local/share/chezmoi-deploy"]`, and with `"server"` does not. Use the render pattern from `zsh_startup_test.sh:504`. Run it. Expected: FAIL.
- [ ] **Step 2:** Implement both edits. Run `bash tests/zssh_test.sh; bash tests/zsh_startup_test.sh`. Expected: 0 failed. Commit: `feat: chezmoi-deploy external on desktops; devcontainer uses this repo`. Push after the owner's go-ahead.
- [ ] **Step 3:** Run `git -C ~/repos/zsh-config log --oneline rolling-bundles..config`. Expected: empty. If it is not empty, stop and port those commits into `~/repos/chezmoi` first.
- [ ] **Step 4:** Back up `cp ~/.config/chezmoi/chezmoi.toml /tmp/opencode/chezmoi.toml.bak`. Set `sourceDir = "/home/jbradshaw/repos/chezmoi"`. Run `chezmoi diff`. Expected: only `~/.local/bin/zssh` and the new external. Show the diff to the owner and run `chezmoi apply` only after approval.
- [ ] **Step 5:** Run `chezmoi source-path`. Expected: `/home/jbradshaw/repos/chezmoi/home`. Run `zssh` against a reachable host the owner names. Expected: the session opens with the bundle built from `~/.local/share/chezmoi-deploy`.
- [ ] **Step 6:** On zsh-config `main`, add a `README.md` that points to both repos. Push after the owner's go-ahead. Deleting `~/repos/config-chezmoi` and archiving zsh-config are left to the owner.

### Task 11: Wrapper CI (in `~/repos/chezmoi-deploy`)

**Files:**
- Create: `.github/workflows/builder-image.yml`, `features.yml`, `tests.yml`, `resolve.yml`
- Create: `portable/lock-diff.sh`, `tests/lock_diff_test.sh`

**Interfaces:**
- `portable/lock-diff.sh OLD_LOCK NEW_LOCK TOOLS_LOCK`: prints markdown.
  - One `- NAME OLD → NEW` line per changed version. A new tool shows `(new)` for OLD; a dropped tool shows `(removed)` for NEW.
  - Then `### Not built` with one `- NAME (HOW)` line per `tools.lock` row whose `how` is `fallback-cache` or `fallback-release`.
  - It prints nothing when the versions are unchanged.
- `resolve.yml` (`on: workflow_call`, input `profile`, default `x86_64-v3`):
  1. Runs in container `ghcr.io/jordanbradshaw/zsh-builder:latest`.
  2. Checks out the caller (path `chezmoi`) and `JordanBradshaw/chezmoi-deploy` (path `deploy`).
  3. `actions/cache` on `~/.cache/zsh-portable/tools`, key `tools-<profile>-<hashFiles(chezmoi/apps/locks/<profile>.lock)>`, restore-key `tools-<profile>-`.
  4. Copies the old lock, then runs `deploy/portable/build-tools.sh --chezmoi chezmoi --profile P --resolve --out out`.
  5. Runs `lock-diff.sh` into the PR body.
  6. `peter-evans/create-pull-request@v7`: `path: chezmoi`, `branch: apps/rolling-<profile>`, `title: apps: rolling update <date>`, `commit-message` the same, `add-paths: apps/locks/<profile>.lock`.
- `tests.yml` (push, pull_request, `schedule: '0 5 * * *'`): installs zsh, chezmoi and eget, checks out chezmoi `main` to `chezmoi`, and runs both test files with `CHEZMOI_SRC`.
- `builder-image.yml` (push to `main` touching `features/src/zsh-builder/**` or `features/builder/**`, plus manual): builds `features/builder/x86_64.Dockerfile` and pushes `ghcr.io/jordanbradshaw/zsh-builder:latest` and `:sha-<short>`.
- `features.yml` (push to `main` touching `features/src/**`): `devcontainers/action@v1` with `publish-features: true`, `base-path-to-features: ./features/src`.

- [ ] **Step 1:** Write `tests/lock_diff_test.sh` with `test_changed_version`, `test_new_and_removed`, `test_fallbacks_listed`, `test_no_change_prints_nothing`. Run it. Expected: FAIL. Implement. Run it. Expected: 0 failed.
- [ ] **Step 2:** Write the four workflows. Run `eget rhysd/actionlint --to /tmp/opencode/actionlint`, then `/tmp/opencode/actionlint .github/workflows/*.yml`. Expected: no output.
- [ ] **Step 3:** Commit: `ci: builder image, features, tests, reusable resolve workflow`. Push after the owner's go-ahead.
- [ ] **Step 4:** Run `gh workflow run builder-image.yml`, wait with `gh run watch`. Expected: success. Ask the owner to set the `zsh-builder` package to public (Package settings), or get approval to run `gh api -X PATCH /user/packages/container/zsh-builder -f visibility=public`. The chezmoi workflow pulls it without credentials.
- [ ] **Step 5:** Run `gh workflow run tests.yml` and `gh run watch`. Expected: success.

### Task 12: chezmoi CI (in `~/repos/chezmoi`)

**Files:**
- Create: `.github/workflows/nightly.yml`, `.github/workflows/tests.yml`

**Interfaces:**
- `nightly.yml`:
  - Triggers: `schedule: '0 4 * * *'`, `workflow_dispatch`.
  - Job `resolve`: `uses: JordanBradshaw/chezmoi-deploy/.github/workflows/resolve.yml@main`, `with: { profile: x86_64-v3 }`, `permissions: { contents: write, pull-requests: write }`.
- `tests.yml` (push, pull_request): installs zsh, tmux, chezmoi, python3, then runs every `tests/*_test.sh` and `tests/zsh/run.sh`.

- [ ] **Step 1:** Write both workflows. Run actionlint on them. Expected: no output.
- [ ] **Step 2:** Commit: `ci: tests and nightly rolling lock PR`. Push after the owner's go-ahead.
- [ ] **Step 3:** With the owner's go-ahead, let Actions open PRs ("Allow GitHub Actions to create and approve pull requests"): `gh api -X PUT repos/JordanBradshaw/chezmoi/actions/permissions/workflow -f default_workflow_permissions=read -F can_approve_pull_request_reviews=true`. Check with `gh api repos/JordanBradshaw/chezmoi/actions/permissions/workflow`. Expected: `"can_approve_pull_request_reviews":true`.
- [ ] **Step 4:** Run `gh workflow run nightly.yml -R JordanBradshaw/chezmoi` and `gh run watch`. Expected: success. Either no PR (nothing changed upstream), or a PR `apps: rolling update <date>` whose body lists `NAME OLD → NEW` lines and whose `tests.yml` check passes.
