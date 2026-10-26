# Phase 1: Builder and `build-tools.sh` Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Cross-build the zssh tools per target profile inside a builder container, from source at reviewed (locked) or latest (resolved) versions, with a cache, ELF checks and fallbacks, producing `bin/` plus `tools.lock` for a bundle.

**Architecture:** A new `scripts/portable/build-tools.sh` (sourceable, like `build.sh`) reads a profile (`profiles/<name>.env`), the extended `tools.tsv` (new `source` column) and a lock (`locks/<profile>.lock`). Each tool is built by its recipe (`crate:` via crates.io source + cargo-zigbuild, `go:` via `go build`, `cross:` via the existing SDK scripts, `release` via the existing eget logic moved into a shared `lib.sh`). A builder image (devcontainer feature `zsh-builder` + Dockerfile) provides the toolchains; `builder.sh` runs commands in it with the repo and cache mounted.

**Tech Stack:** bash, python3 (JSON), cargo + cargo-zigbuild + zig, Go, eget, binutils (`readelf`), docker.

**Spec:** `docs/superpowers/specs/2026-10-26-rolling-bundles-and-devcontainer-feature-design.md` (sections 3, 4 "two version modes", "Rolling back").

## Global Constraints

- All work happens on branch `rolling-bundles` in the worktree `~/repos/zsh-config-rolling`, on top of one baseline commit snapshotting the `config` working tree. Never touch the `config` branch or `~/repos/zsh-config`'s working tree. Never push.
- Profiles, verbatim: `x86_64-v3`: `PROFILE_ARCH=x86_64`, `RUST_TARGET=x86_64-unknown-linux-musl`, `RUST_CPU=x86-64-v3`, `GO_ENV="GOARCH=amd64 GOAMD64=v3 CGO_ENABLED=0"`, `NEEDS_SDK=0`. `qos-orin`: `PROFILE_ARCH=aarch64`, `RUST_TARGET=aarch64-unknown-linux-gnu.2.39`, `RUST_CPU=cortex-a78ae`, `GO_ENV="GOARCH=arm64 CGO_ENABLED=0"`, `NEEDS_SDK=1`.
- Rust build settings: `RUSTFLAGS="-C target-cpu=$RUST_CPU"`, `CARGO_PROFILE_RELEASE_LTO=fat`, `CARGO_PROFILE_RELEASE_CODEGEN_UNITS=1`. Never `target-cpu=native`.
- Go build settings: `GO_ENV` plus `GOOS=linux`, `-trimpath -ldflags='-s -w'`.
- Paths: lock `scripts/portable/locks/<profile>.lock`; cache `${XDG_CACHE_HOME:-~/.cache}/zsh-portable/tools/<profile>/<name>/<version>-<recipehash>/<name>`.
- Lock format (TSV, sorted by name, `#` header line): `name  source  version`. Output `tools.lock` adds `sha256  how` where how ∈ `built|cached|fallback-cache|fallback-release`.
- Verification: ELF arch == `PROFILE_ARCH`; `x86_64-v3` binaries have no `INTERP` program header (static); `qos-orin` binaries need no `GLIBC_` version above `2.39`.
- One tool failing never fails the run; a tool with no binary at all is reported and skipped (as `build.sh` does today).
- Tests follow the repo's style: bash, sandbox PATH stubs, `run_test` loop, `N passed, M failed`.

## Review Focus

1. **Crate without a `Cargo.lock`** in its published package: `--locked` fails; expected: retry once without `--locked` and still build. Test in Task 4.
2. **Crate whose binary name differs or ships several binaries** (`tailspin` → `tspin`, `bottom` → `btm`, `systeroid` + `systeroid-tui`): expected: the tsv `crate:NAME:BIN` picks the right binary. Test in Task 4.
3. **No network with a complete cache under `--locked`**: expected: zero network calls, everything from cache. Test in Task 5.
4. **Version lookup fails under `--resolve`** (GitHub rate limit, crates.io down): expected: that tool keeps its previous lock entry, the run continues. Test in Task 3.
5. **Build killed midway**: expected: no half-written binary in the cache is ever used (build to a temp dir, rename on success). Test in Task 5.

---

### Task 0: Isolated worktree with baseline

**Files:** none in the repo.

- [ ] **Step 1:** `git -C ~/repos/zsh-config worktree add -b rolling-bundles ~/repos/zsh-config-rolling HEAD`
- [ ] **Step 2:** Copy the `config` working tree state: `rsync -a --delete --exclude=.git ~/repos/zsh-config/ ~/repos/zsh-config-rolling/`
- [ ] **Step 3:** In the worktree: `git add -A && git commit -m "baseline: config working tree as of 2026-10-26"`. Verify `git -C ~/repos/zsh-config status` is unchanged and `git -C ~/repos/zsh-config branch --show-current` is `config`.
- [ ] **Step 4:** Run the existing suites in the worktree (`tests/*.sh`, `tests/zsh/run.sh`); record the baseline counts.

### Task 1: Profiles and `build-tools.sh` skeleton

**Files:**
- Create: `scripts/portable/profiles/x86_64-v3.env`, `scripts/portable/profiles/qos-orin.env`
- Create: `scripts/portable/build-tools.sh`
- Test: `tests/build_tools_test.sh`

**Interfaces:**
- Produces: `build-tools.sh` sourceable without running `main` (same `[[ ${BASH_SOURCE[0]} == "$0" ]]` guard as `build.sh`); `load_profile NAME` sets `PROFILE_NAME PROFILE_ARCH RUST_TARGET RUST_CPU GO_ENV NEEDS_SDK`, returns 1 with `unknown profile NAME` on stderr; `rust_target_dir` prints `RUST_TARGET` without a glibc suffix (`aarch64-unknown-linux-gnu.2.39` → `aarch64-unknown-linux-gnu`); `main --profile P [--resolve|--locked] [--only a,b] [--out DIR]` (default `--locked`, out `$CACHE/tools-out/<profile>`).

- [ ] **Step 1:** Tests: `test_load_profile_x86_64_v3` (all six values verbatim), `test_load_profile_qos_orin`, `test_unknown_profile_fails`, `test_rust_target_dir_strips_glibc_suffix`, `test_usage_without_profile_exits_2`.
- [ ] **Step 2:** Run `bash tests/build_tools_test.sh`: all fail.
- [ ] **Step 3:** Implement the profile files and the skeleton (argument parsing, `load_profile`, `rust_target_dir`, `log`/`die` like `build.sh`).
- [ ] **Step 4:** Tests pass.
- [ ] **Step 5:** Commit `feat(portable): build profiles and build-tools skeleton`.

### Task 2: `source` column in `tools.tsv`, shared `lib.sh`

**Files:**
- Modify: `scripts/portable/tools.tsv` (header docs + 5th column on every row)
- Create: `scripts/portable/lib.sh` — move `normalize_arch eget_system asset_candidates asset_args elf_arch load_github_token` from `build.sh`, plus new `fetch_release NAME REPO FILE SPEC ARCH OUT [TAG]` (the eget loop body of `fetch_tools`, with `--tag TAG` when given)
- Modify: `scripts/portable/build.sh` (source `lib.sh`; `fetch_tools` reads `name repo file spec source` and calls `fetch_release`)
- Test: `tests/build_tools_test.sh`, existing `tests/portable_test.sh`

**Interfaces:**
- Produces: `source` values `crate:CRATE[:BIN][:CARGO_ARGS]`, `go:MODULE[//SUBPKG]`, `cross:NAME`, `release`; `fetch_release` returns 0 only with a binary of the right ELF arch at OUT.

- [ ] **Step 1:** Tests: `test_every_tools_row_has_valid_source` (5 columns; source matches `^(crate:[a-z0-9_-]+(:[A-Za-z0-9_-]+)?(:.*)?|go:[^ ]+|cross:[a-z0-9-]+|release)$`); `test_cross_rows_keep_cross_repo` (rows with `repo` `cross:X` have source `cross:X`); `test_known_sources` asserting `rg`→`crate:ripgrep:rg`, `tspin`→`crate:tailspin:tspin`, `btm`→`crate:bottom:btm`, `fzf`→`go:github.com/junegunn/fzf`, `lnav`→`release`, `tmux`→`cross:tmux`.
- [ ] **Step 2:** Run: fail.
- [ ] **Step 3:** Classify every row. Rust (verify each with `cargo search` and the repo's GitHub language; anything unverifiable → `release`): eza lsd bat rg fd delta zoxide atuin btm dust procs bandwhich diskwatch systeroid systeroid-tui systemctl-tui tspin rustnet xfr trip gping tracexec cyme usbtree viddy zellij comchan binsider pueue pueued. Go: fzf direnv duf lazydocker lazyjournal lsoff snitch ctop dive. C/C++: lnav → `release`. Move the shared functions to `lib.sh`; `build.sh` sources it.
- [ ] **Step 4:** New tests pass; `bash tests/portable_test.sh` passes with the Task 0 count (the moved functions are still reachable by sourcing `build.sh`).
- [ ] **Step 5:** Commit `feat(portable): tools.tsv source column, shared lib.sh`.

### Task 3: Versions and locks

**Files:**
- Modify: `scripts/portable/build-tools.sh`
- Create: `scripts/portable/locks/.gitkeep`
- Test: `tests/build_tools_test.sh` (curl stub serving JSON fixtures by URL)

**Interfaces:**
- Produces: `latest_version SOURCE REPO` → prints a version or returns 1 (crate: crates.io `/api/v1/crates/CRATE` → `crate.max_stable_version`; go: `https://proxy.golang.org/<escaped module>/@latest` → `Version`, escaping each uppercase letter as `!` + lowercase; release and cross: GitHub `repos/REPO/releases/latest` → `tag_name`, cross rows use the literal `recipe`); `read_lock FILE` fills assoc array `LOCK[name]=version`; `write_lock FILE` from `LOCK` and `SOURCES[name]`; `resolve_versions` (for `--resolve`, and for names missing from the lock under `--locked`).

- [ ] **Step 1:** Tests: `test_crate_latest_from_crates_io`, `test_go_latest_escapes_uppercase` (`github.com/Lifailon/lazyjournal` → URL contains `github.com/!lifailon/lazyjournal/@latest`), `test_release_latest_from_github`, `test_locked_makes_no_lookups` (curl stub logs nothing), `test_missing_lock_entry_is_resolved`, `test_resolve_rewrites_lock_sorted_with_header`, `test_failed_lookup_keeps_old_entry` (Review Focus 4: curl stub fails for one URL; lock keeps that tool's old version; exit 0).
- [ ] **Step 2:** Run: fail.
- [ ] **Step 3:** Implement with python3 for JSON; GitHub requests send `Authorization: Bearer $EGET_GITHUB_TOKEN` when set (`load_github_token` from `lib.sh`).
- [ ] **Step 4:** Pass.
- [ ] **Step 5:** Commit `feat(portable): resolve and lock tool versions`.

### Task 4: Recipe builders

**Files:**
- Modify: `scripts/portable/build-tools.sh`
- Test: `tests/build_tools_test.sh` (stubs: curl, tar, cargo, go, eget, cross script)

**Interfaces:**
- Produces: `build_recipe NAME SOURCE REPO FILE SPEC VERSION OUT` → 0 with a binary at OUT. crate: download `https://crates.io/api/v1/crates/CRATE/VERSION/download`, unpack, `cargo zigbuild --release --locked --target "$RUST_TARGET" --bin BIN CARGO_ARGS` with the Rust settings from Global Constraints, copy `target/$(rust_target_dir)/release/BIN`; retry once without `--locked` when the package has no `Cargo.lock`. go: `GOPATH=<tmp> GOMODCACHE=$CACHE/gomod GOOS=linux $GO_ENV go install -trimpath -ldflags='-s -w' MODULE[/SUBPKG]@VERSION`, take the binary from `<tmp>/bin/` or `<tmp>/bin/linux_<goarch>/`. cross: `cross/NAME.sh $PROFILE_ARCH OUT`, only when `NEEDS_SDK=1`, else return 1. release: `fetch_release ... $PROFILE_ARCH OUT VERSION`.

- [ ] **Step 1:** Tests: `test_crate_build_uses_zigbuild_target_and_cpu` (logged cargo args and env verbatim), `test_crate_without_cargo_lock_retries_unlocked` (Review Focus 1), `test_crate_bin_differs_from_crate` (`crate:tailspin:tspin` copies `release/tspin`; Review Focus 2), `test_crate_extra_args_passed`, `test_go_build_env_and_flags`, `test_go_cross_binary_found_in_goarch_dir`, `test_cross_needs_sdk_profile`, `test_release_passes_tag`.
- [ ] **Step 2:** Run: fail.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Pass.
- [ ] **Step 5:** Commit `feat(portable): crate, go, cross and release recipes`.

### Task 5: Verify, cache, fall back, output

**Files:**
- Modify: `scripts/portable/build-tools.sh`
- Test: `tests/build_tools_test.sh` (readelf stub with fixture outputs)

**Interfaces:**
- Consumes: `build_recipe`, `read_lock`, `elf_arch`.
- Produces: `verify_binary FILE` (rules from Global Constraints); `recipe_hash NAME` = sha256 of the tool's tsv row + the profile file, first 12 hex; `main` fills `OUT/bin/<name>` and writes `OUT/tools.lock`.

- [ ] **Step 1:** Tests: `test_verify_rejects_wrong_arch`, `test_verify_rejects_dynamic_for_x86_64_v3`, `test_verify_rejects_glibc_above_2_39_for_qos`, `test_cache_hit_skips_build`, `test_recipe_change_rebuilds`, `test_locked_full_cache_works_offline` (Review Focus 3: every network/build stub fails, all tools come from cache), `test_killed_build_never_cached` (Review Focus 5: build stub writes a partial file then fails; cache dir has no entry; next run rebuilds), `test_failed_build_uses_newest_cached_version` (`how=fallback-cache`), `test_failed_build_without_cache_uses_release` (`how=fallback-release`), `test_tool_with_nothing_is_reported_and_skipped`, `test_tools_lock_lists_sha256_and_how`, `test_only_limits_tools`.
- [ ] **Step 2:** Run: fail.
- [ ] **Step 3:** Implement: build into `mktemp -d` under the cache, verify, then `mv` to the final cache path.
- [ ] **Step 4:** Pass; the whole `tests/build_tools_test.sh` passes.
- [ ] **Step 5:** Commit `feat(portable): verified, cached tool builds with fallbacks`.

### Task 6: Builder image and runner, real x86_64-v3 build

**Files:**
- Create: `features/src/zsh-builder/devcontainer-feature.json` (id `zsh-builder`, version `0.1.0`, options `rustTargets` default `x86_64-unknown-linux-musl,aarch64-unknown-linux-gnu`, `goVersion` default `latest`)
- Create: `features/src/zsh-builder/install.sh` (root; apt: `build-essential pkg-config git curl ca-certificates xz-utils python3 binutils file rsync`; rustup minimal stable + targets; zig (latest stable tarball from ziglang.org, to `/usr/local/zig`); `cargo install --locked cargo-zigbuild`; Go from go.dev; eget to `/usr/local/bin`; everything on PATH via `/etc/profile.d/zsh-builder.sh` and `ENV`-equivalent `containerEnv` in the json)
- Create: `features/builder/x86_64.Dockerfile` (`FROM ubuntu:24.04`, copy the feature, run `install.sh`)
- Create: `scripts/portable/builder.sh` (`builder.sh image` builds `zsh-builder:local`; `builder.sh run CMD...` runs CMD in it as the invoking uid with the repo at `/src` and `${XDG_CACHE_HOME:-~/.cache}/zsh-portable` at the same path inside, `HOME=/tmp/home`)
- Test: `tests/build_tools_test.sh` (opt-in `BUILDER_E2E=1`)

**Interfaces:**
- Consumes: `build-tools.sh main`.

- [ ] **Step 1:** Tests: `test_feature_json_valid` (python3 json load; id, version, options), `test_builder_run_mounts_repo_and_cache` (docker stub logs `-v` args and `--user`), and opt-in `test_e2e_x86_64_v3_builds_rg_and_fzf`: `builder.sh image`, then `builder.sh run scripts/portable/build-tools.sh --profile x86_64-v3 --resolve --only rg,fzf --out /tmp/out`; assert `elf_arch` x86_64, no `INTERP`, `rg --version` and `fzf --version` run on the host, `tools.lock` has both with `how=built`.
- [ ] **Step 2:** Run: unit tests fail; e2e fails.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Unit tests pass; `BUILDER_E2E=1 bash tests/build_tools_test.sh` passes (expect the first image build to take several minutes).
- [ ] **Step 5:** Full real run: `builder.sh run scripts/portable/build-tools.sh --profile x86_64-v3 --resolve`; commit the resulting `locks/x86_64-v3.lock`. Record which tools fell back (and why) in the commit message.
- [ ] **Step 6:** All suites from Task 0 still pass. Commit `feat(portable): zsh-builder feature, image and runner`.
