#!/usr/bin/env bash
#
# Tests for scripts/portable/build-tools.sh: profiles, tools.tsv sources,
# version locks, recipes, verification, cache and fallbacks.
#
# Network, compilers and eget are stubs on a sandboxed PATH that log their
# arguments, so nothing is downloaded or built. BUILDER_E2E=1 adds a real
# build in the builder container.

set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_TOOLS="$REPO_DIR/scripts/portable/build-tools.sh"
TOOLS_TSV="$REPO_DIR/scripts/portable/tools.tsv"
BASH_BIN="$(command -v bash)"
PASS=0
FAIL=0

setup() {
    SANDBOX="$(mktemp -d)"
    OUTPUT=""
    STATUS=0
}

teardown() {
    rm -rf "$SANDBOX"
}

CURRENT=""

fail() {
    echo "  FAIL [$CURRENT]: $*"
    FAIL=$((FAIL + 1))
    return 1
}

assert_eq() { [[ $1 == "$2" ]] || fail "expected '$2', got '$1'"; }

run_test() {
    CURRENT="$1"
    setup
    local before=$FAIL
    "$1"
    [[ $FAIL -eq $before ]] && PASS=$((PASS + 1)) && echo "  ok   $1"
    teardown
}

# bt CODE: run CODE in bash after sourcing build-tools.sh (main not run).
bt() {
    OUTPUT="$("$BASH_BIN" -c "source '$BUILD_TOOLS'; $1" 2>&1)"
    STATUS=$?
}

# ---------------------------------------------------------------------------
# Profiles
# ---------------------------------------------------------------------------

test_load_profile_x86_64_v3() {
    bt 'load_profile x86_64-v3 && printf "%s|" "$PROFILE_NAME" "$PROFILE_ARCH" "$RUST_TARGET" "$RUST_CPU" "$GO_ENV" "$NEEDS_SDK"'
    assert_eq "$OUTPUT" "x86_64-v3|x86_64|x86_64-unknown-linux-musl|x86-64-v3|GOARCH=amd64 GOAMD64=v3 CGO_ENABLED=0|0|"
}

test_load_profile_qos_orin() {
    bt 'load_profile qos-orin && printf "%s|" "$PROFILE_NAME" "$PROFILE_ARCH" "$RUST_TARGET" "$RUST_CPU" "$GO_ENV" "$NEEDS_SDK"'
    assert_eq "$OUTPUT" "qos-orin|aarch64|aarch64-unknown-linux-gnu.2.39|cortex-a78ae|GOARCH=arm64 CGO_ENABLED=0|1|"
}

test_unknown_profile_fails() {
    bt 'load_profile pdp11'
    [[ $STATUS -ne 0 ]] || fail "unknown profile accepted"
    [[ $OUTPUT == *"unknown profile pdp11"* ]] || fail "no message: $OUTPUT"
    return 0
}

test_rust_target_dir_strips_glibc_suffix() {
    bt 'load_profile qos-orin && rust_target_dir; load_profile x86_64-v3 && rust_target_dir'
    assert_eq "$OUTPUT" "aarch64-unknown-linux-gnu
x86_64-unknown-linux-musl"
}

test_usage_without_profile_exits_2() {
    OUTPUT="$("$BASH_BIN" "$BUILD_TOOLS" 2>&1)"
    STATUS=$?
    assert_eq "$STATUS" 2
    [[ $OUTPUT == *Usage* ]] || fail "no usage: $OUTPUT"
    return 0
}

# ---------------------------------------------------------------------------
# tools.tsv sources
# ---------------------------------------------------------------------------

# tsv_rows: tools.tsv without comments and blank lines.
tsv_rows() {
    grep -vE '^[[:space:]]*(#|$)' "$TOOLS_TSV"
}

test_every_tools_row_has_valid_source() {
    local name repo file spec source extra
    while read -r name repo file spec source extra; do
        [[ -n $source && -z $extra ]] || { fail "$name: expected 5 columns"; continue; }
        [[ $source =~ ^(crate:[a-z0-9_-]+(:[A-Za-z0-9_-]+)?(:.*)?|go:[^[:space:]]+|cross:[a-z0-9-]+|release)$ ]] ||
            fail "$name: bad source '$source'"
    done < <(tsv_rows)
    return 0
}

test_cross_rows_keep_cross_repo() {
    local name repo file spec source
    while read -r name repo file spec source; do
        [[ $repo == cross:* ]] || continue
        assert_eq "$source" "$repo"
    done < <(tsv_rows)
}

# source_of NAME: the source column of NAME's row.
source_of() {
    tsv_rows | awk -v n="$1" '$1 == n { print $5 }'
}

test_known_sources() {
    assert_eq "$(source_of rg)" "crate:ripgrep:rg"
    assert_eq "$(source_of tspin)" "crate:tailspin:tspin"
    assert_eq "$(source_of btm)" "crate:bottom:btm"
    assert_eq "$(source_of pueued)" "crate:pueue:pueued"
    assert_eq "$(source_of fzf)" "go:github.com/junegunn/fzf"
    assert_eq "$(source_of direnv)" "go:github.com/direnv/direnv/v2"
    assert_eq "$(source_of lnav)" "release"
    assert_eq "$(source_of tmux)" "cross:tmux"
    # crates.io names taken by other projects: built from releases.
    assert_eq "$(source_of usbtree)" "release"
    assert_eq "$(source_of rustnet)" "release"
}

# build.sh still reads the eget columns (repo file assets) correctly with the
# extra column: the source must not leak into the asset filters.
test_build_sh_ignores_source_column() {
    OUTPUT="$("$BASH_BIN" -c "source '$REPO_DIR/scripts/portable/build.sh'
        while read -r name repo file spec source; do
            [[ \$name == rg ]] && asset_candidates x86_64 \"\$spec\"
        done < <(grep -vE '^[[:space:]]*(#|\$)' '$TOOLS_TSV')" 2>&1)"
    [[ $OUTPUT != *crate:* ]] || fail "source leaked into asset filters: $OUTPUT"
    [[ -n $OUTPUT ]] || fail "no asset candidates"
    return 0
}

test_lib_sh_provides_shared_functions() {
    OUTPUT="$("$BASH_BIN" -c "source '$REPO_DIR/scripts/portable/lib.sh'
        for f in normalize_arch eget_system asset_candidates asset_args elf_arch load_github_token fetch_release; do
            declare -F \$f >/dev/null || echo missing:\$f
        done" 2>&1)"
    assert_eq "$OUTPUT" ""
}

# ---------------------------------------------------------------------------
# Versions and locks
# ---------------------------------------------------------------------------

# stubs_setup: stub dir first on PATH; curl serves $SANDBOX/fixtures/<url
# with / and : replaced by _> and logs every URL; a URL containing any word
# of $STUB_CURL_FAIL fails.
stubs_setup() {
    STUBS="$SANDBOX/stubs"
    STUB_LOG="$SANDBOX/calls.log"
    mkdir -p "$STUBS" "$SANDBOX/fixtures"
    : >"$STUB_LOG"
    cat >"$STUBS/curl" <<'EOF'
#!/usr/bin/env bash
url="${@: -1}"
echo "curl $url" >>"$STUB_LOG"
for bad in ${STUB_CURL_FAIL:-}; do [[ $url == *"$bad"* ]] && exit 22; done
f="$FIXTURES/$(printf '%s' "$url" | tr '/:' '__')"
[[ -f $f ]] || exit 22
cat "$f"
EOF
    chmod +x "$STUBS/curl"
    export STUB_LOG FIXTURES="$SANDBOX/fixtures" STUB_CURL_FAIL=""
}

# fixture URL JSON: what the curl stub returns for URL.
fixture() {
    printf '%s\n' "$2" >"$FIXTURES/$(printf '%s' "$1" | tr '/:' '__')"
}

# use_tools ROWS: a small tools.tsv for the test (TOOLS_FILE), and a locks
# dir (LOCKS_DIR) in the sandbox.
use_tools() {
    printf '%s\n' "$1" >"$SANDBOX/tools.tsv"
    mkdir -p "$SANDBOX/locks"
    export TOOLS_FILE="$SANDBOX/tools.tsv" LOCKS_DIR="$SANDBOX/locks"
}

# btp CODE: bt with the stubs first on PATH.
btp() {
    OUTPUT="$(PATH="$STUBS:$PATH" "$BASH_BIN" -c "source '$BUILD_TOOLS'; $1" 2>&1)"
    STATUS=$?
}

TWO_TOOLS='rg  BurntSushi/ripgrep  rg   musl|gnu  crate:ripgrep:rg
fzf junegunn/fzf        fzf  tar.gz    go:github.com/junegunn/fzf'

test_crate_latest_from_crates_io() {
    stubs_setup
    fixture https://crates.io/api/v1/crates/ripgrep '{"crate":{"max_stable_version":"15.2.0","max_version":"16.0.0-rc1"}}'
    btp 'latest_version crate:ripgrep:rg BurntSushi/ripgrep'
    assert_eq "$OUTPUT" "15.2.0"
}

test_go_latest_escapes_uppercase() {
    stubs_setup
    fixture https://proxy.golang.org/github.com/!lifailon/lazyjournal/@latest '{"Version":"v0.8.4"}'
    btp 'latest_version go:github.com/Lifailon/lazyjournal Lifailon/lazyjournal'
    assert_eq "$OUTPUT" "v0.8.4"
}

test_go_latest_uses_module_not_subpackage() {
    stubs_setup
    fixture https://proxy.golang.org/github.com/x/tool/@latest '{"Version":"v1.2.3"}'
    btp 'latest_version go:github.com/x/tool//cmd/tool x/tool'
    assert_eq "$OUTPUT" "v1.2.3"
}

# Modules without v-prefixed semver tags only get pseudo-versions of the
# default branch from the proxy; their GitHub release tag is the release.
test_go_pseudo_version_prefers_release_tag() {
    stubs_setup
    fixture https://proxy.golang.org/github.com/!lifailon/lazyjournal/@latest '{"Version":"v0.0.0-20261026112250-ca677bc44ea2"}'
    fixture https://api.github.com/repos/Lifailon/lazyjournal/releases/latest '{"tag_name":"0.8.4"}'
    btp 'latest_version go:github.com/Lifailon/lazyjournal Lifailon/lazyjournal'
    assert_eq "$OUTPUT" "0.8.4"
}

test_go_pseudo_version_kept_without_release() {
    stubs_setup
    fixture https://proxy.golang.org/github.com/x/tool/@latest '{"Version":"v0.0.0-20261026112250-ca677bc44ea2"}'
    btp 'latest_version go:github.com/x/tool x/tool'
    assert_eq "$OUTPUT" "v0.0.0-20261026112250-ca677bc44ea2"
}

test_release_latest_from_github() {
    stubs_setup
    fixture https://api.github.com/repos/tstack/lnav/releases/latest '{"tag_name":"v0.13.2"}'
    btp 'latest_version release tstack/lnav'
    assert_eq "$OUTPUT" "v0.13.2"
}

test_cross_version_is_recipe() {
    stubs_setup
    btp 'latest_version cross:tmux cross:tmux'
    assert_eq "$OUTPUT" "recipe"
    assert_eq "$(cat "$STUB_LOG")" ""
}

test_locked_makes_no_lookups() {
    stubs_setup
    use_tools "$TWO_TOOLS"
    printf 'rg\tcrate:ripgrep:rg\t15.1.0\nfzf\tgo:github.com/junegunn/fzf\tv0.60.0\n' >"$LOCKS_DIR/x86_64-v3.lock"
    btp 'load_profile x86_64-v3; resolve_versions locked; echo "${LOCK[rg]} ${LOCK[fzf]}"'
    assert_eq "$OUTPUT" "15.1.0 v0.60.0"
    assert_eq "$(cat "$STUB_LOG")" ""
}

test_missing_lock_entry_is_resolved() {
    stubs_setup
    use_tools "$TWO_TOOLS"
    printf 'rg\tcrate:ripgrep:rg\t15.1.0\n' >"$LOCKS_DIR/x86_64-v3.lock"
    fixture https://proxy.golang.org/github.com/junegunn/fzf/@latest '{"Version":"v0.66.0"}'
    btp 'load_profile x86_64-v3; resolve_versions locked; echo "${LOCK[rg]} ${LOCK[fzf]}"'
    assert_eq "$OUTPUT" "15.1.0 v0.66.0"
    assert_eq "$(cat "$STUB_LOG")" "curl https://proxy.golang.org/github.com/junegunn/fzf/@latest"
}

test_resolve_rewrites_lock_sorted_with_header() {
    stubs_setup
    use_tools "$TWO_TOOLS"
    printf 'rg\tcrate:ripgrep:rg\t15.1.0\n' >"$LOCKS_DIR/x86_64-v3.lock"
    fixture https://crates.io/api/v1/crates/ripgrep '{"crate":{"max_stable_version":"15.2.0"}}'
    fixture https://proxy.golang.org/github.com/junegunn/fzf/@latest '{"Version":"v0.66.0"}'
    btp 'load_profile x86_64-v3; resolve_versions resolve; write_lock'
    assert_eq "$STATUS" 0
    assert_eq "$(cat "$LOCKS_DIR/x86_64-v3.lock")" "# build-tools.sh lock for x86_64-v3: name, source, version. Rewrite with --resolve.
fzf	go:github.com/junegunn/fzf	v0.66.0
rg	crate:ripgrep:rg	15.2.0"
}

test_failed_lookup_keeps_old_entry() {
    stubs_setup
    use_tools "$TWO_TOOLS"
    printf 'rg\tcrate:ripgrep:rg\t15.1.0\nfzf\tgo:github.com/junegunn/fzf\tv0.60.0\n' >"$LOCKS_DIR/x86_64-v3.lock"
    fixture https://proxy.golang.org/github.com/junegunn/fzf/@latest '{"Version":"v0.66.0"}'
    STUB_CURL_FAIL=crates.io btp 'load_profile x86_64-v3; resolve_versions resolve; echo "${LOCK[rg]} ${LOCK[fzf]}"'
    assert_eq "$STATUS" 0
    [[ $OUTPUT == *"15.1.0 v0.66.0"* ]] || fail "old entry not kept: $OUTPUT"
    [[ $OUTPUT == *"rg"*"keeping 15.1.0"* ]] || fail "no warning: $OUTPUT"
    return 0
}

test_only_limits_resolution() {
    stubs_setup
    use_tools "$TWO_TOOLS"
    fixture https://crates.io/api/v1/crates/ripgrep '{"crate":{"max_stable_version":"15.2.0"}}'
    btp 'load_profile x86_64-v3; ONLY=rg; resolve_versions resolve; echo "${LOCK[rg]}|${LOCK[fzf]:-}"'
    assert_eq "$OUTPUT" "15.2.0|"
}

test_only_keeps_other_lock_entries() {
    stubs_setup
    use_tools "$TWO_TOOLS"
    printf 'rg\tcrate:ripgrep:rg\t15.1.0\nfzf\tgo:github.com/junegunn/fzf\tv0.60.0\n' >"$LOCKS_DIR/x86_64-v3.lock"
    fixture https://crates.io/api/v1/crates/ripgrep '{"crate":{"max_stable_version":"15.2.0"}}'
    btp 'load_profile x86_64-v3; ONLY=rg; resolve_versions resolve; write_lock'
    grep -qx $'fzf\tgo:github.com/junegunn/fzf\tv0.60.0' "$LOCKS_DIR/x86_64-v3.lock" || fail "fzf entry dropped: $(cat "$LOCKS_DIR/x86_64-v3.lock")"
    grep -qx $'rg\tcrate:ripgrep:rg\t15.2.0' "$LOCKS_DIR/x86_64-v3.lock" || fail "rg not updated"
    return 0
}

# ---------------------------------------------------------------------------

for t in $(declare -F | awk '{print $3}' | grep '^test_'); do
    run_test "$t"
done

echo
echo "$PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
