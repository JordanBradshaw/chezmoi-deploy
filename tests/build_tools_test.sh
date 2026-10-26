#!/usr/bin/env bash
#
# Tests for portable/build-tools.sh: profiles, tools.tsv sources,
# version locks, recipes, verification, cache and fallbacks.
#
# Network, compilers and eget are stubs on a sandboxed PATH that log their
# arguments, so nothing is downloaded or built. BUILDER_E2E=1 adds a real
# build in the builder container.

set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export CHEZMOI_SRC="$REPO_DIR"
BUILD_TOOLS="$REPO_DIR/portable/build-tools.sh"
TOOLS_TSV="$REPO_DIR/portable/tools.tsv"
BASH_BIN="$(command -v bash)"
PASS=0
FAIL=0

setup() {
    SANDBOX="$(mktemp -d)"
    export SANDBOX
    unset TOOLS_FILE LOCKS_DIR XDG_CACHE_HOME CROSS_DIR FIXTURES STUB_LOG STUB_CURL_FAIL STUB_DIE EGET_GITHUB_TOKEN \
        STUB_ELF_ARCH STUB_GO_CROSS STUB_CARGO_FAIL STUB_EGET_FAIL MAKE_ELF
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

test_lib_sh_provides_shared_functions() {
    OUTPUT="$("$BASH_BIN" -c "source '$REPO_DIR/portable/lib.sh'; resolve_chezmoi_src
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
    # Like curl: -o FILE and -w '%{http_code}' are honoured; a URL with a
    # word of $STUB_CURL_FAIL answers 500, one without a fixture 404 (both
    # exit 22 without -w). Full arguments go to $SANDBOX/curl-args.log.
    cat >"$STUBS/curl" <<'EOF'
#!/usr/bin/env bash
url="${@: -1}" out="" code=""
echo "curl $url" >>"$STUB_LOG"
echo "$*" >>"$SANDBOX/curl-args.log"
for ((i = 1; i < $#; i++)); do
    j=$((i + 1))
    case ${!i} in -o) out=${!j} ;; -w) code=1 ;; esac
done
status=200
f="$FIXTURES/$(printf '%s' "$url" | tr '/:' '__')"
[[ -f $f ]] || status=404
for bad in ${STUB_CURL_FAIL:-}; do [[ $url == *"$bad"* ]] && status=500; done
if [[ $status == 200 ]]; then
    if [[ -n $out ]]; then cat "$f" >"$out"; else cat "$f"; fi
fi
[[ -n $code ]] && { printf '%s' "$status"; exit 0; }
[[ $status == 200 ]] || exit 22
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
# Recipes
# ---------------------------------------------------------------------------

# make_elf ARCH FILE: a minimal file elf_arch reads as an ARCH binary.
make_elf() {
    local machine
    case $1 in x86_64) machine='\x3e\x00' ;; aarch64) machine='\xb7\x00' ;; esac
    printf "\x7fELF\x02\x01\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x02\x00$machine" >"$2"
    chmod +x "$2"
}

# recipe_stubs: cargo, go, eget stubs (plus curl from stubs_setup) that log
# their arguments and the build settings they see, and leave fake binaries
# where the real tools would.
recipe_stubs() {
    stubs_setup
    export XDG_CACHE_HOME="$SANDBOX/cache" CROSS_DIR="$SANDBOX/cross"
    MAKE_ELF="$(declare -f make_elf)"
    export MAKE_ELF
    cat >"$STUBS/cargo" <<'EOF'
#!/usr/bin/env bash
eval "$MAKE_ELF"
echo "cargo $* [in ${PWD##*/}]" >>"$STUB_LOG"
echo "cargo-env RUSTFLAGS=$RUSTFLAGS LTO=$CARGO_PROFILE_RELEASE_LTO CGU=$CARGO_PROFILE_RELEASE_CODEGEN_UNITS STRIP=${CARGO_PROFILE_RELEASE_STRIP:-} TOOLCHAIN=${RUSTUP_TOOLCHAIN:-}" >>"$STUB_LOG"
[[ -n ${STUB_CARGO_FAIL:-} ]] && exit 101
target="" bin=""
while (( $# )); do
    case $1 in --target) target=${2%%.[0-9]*}; shift ;; --bin) bin=$2; shift ;; esac
    shift
done
mkdir -p "$CARGO_TARGET_DIR/$target/release"
make_elf "${STUB_ELF_ARCH:-x86_64}" "$CARGO_TARGET_DIR/$target/release/$bin"
EOF
    cat >"$STUBS/go" <<'EOF'
#!/usr/bin/env bash
eval "$MAKE_ELF"
echo "go $*" >>"$STUB_LOG"
echo "go-env GOOS=$GOOS GOARCH=$GOARCH GOAMD64=${GOAMD64:-} CGO_ENABLED=$CGO_ENABLED" >>"$STUB_LOG"
pkg="${@: -1}"; pkg=${pkg%@*}; name=${pkg##*/}
[[ $name =~ ^v[0-9]+$ ]] && { pkg=${pkg%/*}; name=${pkg##*/}; }
dir="$GOPATH/bin"
[[ -n ${STUB_GO_CROSS:-} ]] && dir="$GOPATH/bin/linux_$GOARCH"
mkdir -p "$dir"
make_elf "${STUB_ELF_ARCH:-x86_64}" "$dir/$name"
EOF
    cat >"$STUBS/eget" <<'EOF'
#!/usr/bin/env bash
eval "$MAKE_ELF"
echo "eget $*" >>"$STUB_LOG"
[[ -n ${STUB_EGET_FAIL:-} ]] && exit 1
out=""
for ((i = 1; i <= $#; i++)); do [[ ${!i} == --to ]] && { j=$((i + 1)); out=${!j}; }; done
make_elf "${STUB_ELF_ARCH:-x86_64}" "$out"
EOF
    chmod +x "$STUBS/cargo" "$STUBS/go" "$STUBS/eget"
    mkdir -p "$CROSS_DIR"
}

# crate_fixture CRATE VERSION [nolock]: the crates.io download for CRATE.
crate_fixture() {
    local d="$SANDBOX/pkg/$1-$2"
    mkdir -p "$d"
    printf '[package]\nname = "%s"\n' "$1" >"$d/Cargo.toml"
    [[ ${3:-} == nolock ]] || : >"$d/Cargo.lock"
    tar -czf "$FIXTURES/$(printf '%s' "https://crates.io/api/v1/crates/$1/$2/download" | tr '/:' '__')" \
        -C "$SANDBOX/pkg" "$1-$2"
}

test_crate_build_uses_zigbuild_target_and_cpu() {
    recipe_stubs
    crate_fixture ripgrep 15.2.0
    btp 'load_profile x86_64-v3; build_recipe rg crate:ripgrep:rg BurntSushi/ripgrep rg - 15.2.0 "$SANDBOX/out/rg"'
    assert_eq "$STATUS" 0
    grep -qx "cargo zigbuild --release --locked --target x86_64-unknown-linux-musl --bin rg \[in ripgrep-15.2.0\]" "$STUB_LOG" ||
        fail "cargo call: $(cat "$STUB_LOG")"
    grep -qx "cargo-env RUSTFLAGS=-C target-cpu=x86-64-v3 LTO=fat CGU=1 STRIP=symbols TOOLCHAIN=stable" "$STUB_LOG" || fail "cargo env: $(cat "$STUB_LOG")"
    [[ -x $SANDBOX/out/rg ]] || fail "no binary"
    return 0
}

test_crate_qos_target_keeps_glibc_suffix() {
    recipe_stubs
    crate_fixture ripgrep 15.2.0
    STUB_ELF_ARCH=aarch64 btp 'load_profile qos-orin; build_recipe rg crate:ripgrep:rg BurntSushi/ripgrep rg - 15.2.0 "$SANDBOX/out/rg"'
    grep -q -- "--target aarch64-unknown-linux-gnu.2.39 " "$STUB_LOG" || fail "target: $(cat "$STUB_LOG")"
    grep -q "RUSTFLAGS=-C target-cpu=cortex-a78ae " "$STUB_LOG" || fail "cpu"
    [[ -x $SANDBOX/out/rg ]] || fail "binary not taken from the suffix-less target dir"
    return 0
}

test_crate_without_cargo_lock_builds_unlocked() {
    recipe_stubs
    crate_fixture diskwatch 0.7.0 nolock
    btp 'load_profile x86_64-v3; build_recipe diskwatch crate:diskwatch x/diskwatch diskwatch - 0.7.0 "$SANDBOX/out/diskwatch"'
    assert_eq "$STATUS" 0
    grep -q "^cargo zigbuild --release --target" "$STUB_LOG" || fail "expected no --locked: $(cat "$STUB_LOG")"
    return 0
}

test_crate_bin_differs_from_crate() {
    recipe_stubs
    crate_fixture tailspin 7.0.0
    btp 'load_profile x86_64-v3; build_recipe tspin crate:tailspin:tspin x/tailspin tspin - 7.0.0 "$SANDBOX/out/tspin"'
    grep -q -- "--bin tspin " "$STUB_LOG" || fail "bin: $(cat "$STUB_LOG")"
    [[ -x $SANDBOX/out/tspin ]] || fail "no tspin"
    return 0
}

test_crate_extra_args_passed() {
    recipe_stubs
    crate_fixture atuin 18.0.0
    btp 'load_profile x86_64-v3; build_recipe atuin crate:atuin:atuin:--no-default-features,--features=client x/atuin atuin - 18.0.0 "$SANDBOX/out/atuin"'
    grep -q -- "--bin atuin --no-default-features --features=client " "$STUB_LOG" || fail "args: $(cat "$STUB_LOG")"
    return 0
}

test_crate_build_failure_fails() {
    recipe_stubs
    crate_fixture ripgrep 15.2.0
    STUB_CARGO_FAIL=1 btp 'load_profile x86_64-v3; build_recipe rg crate:ripgrep:rg x/rg rg - 15.2.0 "$SANDBOX/out/rg"'
    [[ $STATUS -ne 0 ]] || fail "failure not reported"
    [[ -e $SANDBOX/out/rg ]] && fail "binary left behind"
    return 0
}

test_go_build_env_and_flags() {
    recipe_stubs
    btp 'load_profile x86_64-v3; build_recipe fzf go:github.com/junegunn/fzf junegunn/fzf fzf - v0.66.0 "$SANDBOX/out/fzf"'
    assert_eq "$STATUS" 0
    grep -qx "go install -trimpath -ldflags=-s -w github.com/junegunn/fzf@v0.66.0" "$STUB_LOG" || fail "go call: $(cat "$STUB_LOG")"
    grep -qx "go-env GOOS=linux GOARCH=amd64 GOAMD64=v3 CGO_ENABLED=0" "$STUB_LOG" || fail "go env: $(cat "$STUB_LOG")"
    [[ -x $SANDBOX/out/fzf ]] || fail "no binary"
    return 0
}

test_go_major_version_suffix_and_subpackage() {
    recipe_stubs
    btp 'load_profile x86_64-v3; build_recipe direnv go:github.com/direnv/direnv/v2 direnv/direnv direnv - v2.38.2 "$SANDBOX/out/direnv"
         build_recipe tool go:github.com/x/mod//cmd/tool x/mod tool - v1.0.0 "$SANDBOX/out/tool"'
    [[ -x $SANDBOX/out/direnv ]] || fail "direnv not found under its /v2 module"
    grep -q "go install .* github.com/x/mod/cmd/tool@v1.0.0" "$STUB_LOG" || fail "subpackage: $(cat "$STUB_LOG")"
    [[ -x $SANDBOX/out/tool ]] || fail "no tool"
    return 0
}

test_go_cross_binary_found_in_goarch_dir() {
    recipe_stubs
    STUB_GO_CROSS=1 STUB_ELF_ARCH=aarch64 btp 'load_profile qos-orin; build_recipe fzf go:github.com/junegunn/fzf junegunn/fzf fzf - v0.66.0 "$SANDBOX/out/fzf"'
    assert_eq "$STATUS" 0
    [[ -x $SANDBOX/out/fzf ]] || fail "binary in bin/linux_arm64 not found"
    return 0
}

test_cross_needs_sdk_profile() {
    recipe_stubs
    printf '#!/usr/bin/env bash\necho "cross $*" >>"$STUB_LOG"\nprintf x >"$2"\n' >"$CROSS_DIR/tmux.sh"
    chmod +x "$CROSS_DIR/tmux.sh"
    btp 'load_profile x86_64-v3; build_recipe tmux cross:tmux cross:tmux tmux - recipe "$SANDBOX/out/tmux"'
    [[ $STATUS -ne 0 ]] || fail "cross recipe ran without the SDK"
    btp 'load_profile qos-orin; build_recipe tmux cross:tmux cross:tmux tmux - recipe "$SANDBOX/out/tmux"'
    assert_eq "$STATUS" 0
    grep -qx "cross aarch64 $SANDBOX/out/tmux" "$STUB_LOG" || fail "cross call: $(cat "$STUB_LOG")"
    return 0
}

test_release_passes_tag() {
    recipe_stubs
    btp 'load_profile x86_64-v3; build_recipe lnav release tstack/lnav lnav musl v0.14.1 "$SANDBOX/out/lnav"'
    assert_eq "$STATUS" 0
    grep -q "^eget .*--tag v0.14.1 .*tstack/lnav$" "$STUB_LOG" || fail "eget: $(cat "$STUB_LOG")"
    return 0
}

# ---------------------------------------------------------------------------
# Verification, cache, fallbacks, output
# ---------------------------------------------------------------------------

# readelf_stub: readelf that reports an INTERP header when
# $STUB_READELF_INTERP is set and GLIBC_<v> needs for $STUB_READELF_GLIBC.
readelf_stub() {
    cat >"$STUBS/readelf" <<'EOF'
#!/usr/bin/env bash
case $1 in
    -lW) [[ -n ${STUB_READELF_INTERP:-} ]] && echo "  INTERP         0x000318 0x0000000000000318" ;;
    -VW) for v in ${STUB_READELF_GLIBC:-}; do echo "  0x0010:   Name: GLIBC_$v  Flags: none  Version: 2"; done ;;
esac
exit 0
EOF
    chmod +x "$STUBS/readelf"
}

# main_stubs ROWS LOCK: recipe and readelf stubs, a small tools.tsv and a
# lock (printf format, tab-separated).
main_stubs() {
    recipe_stubs
    readelf_stub
    use_tools "$1"
    [[ -n ${2:-} ]] && printf "$2" >"$LOCKS_DIR/x86_64-v3.lock"
    export STUB_READELF_INTERP="" STUB_READELF_GLIBC=""
}

RG_ONLY='rg  BurntSushi/ripgrep  rg  musl|gnu  crate:ripgrep:rg'
RG_LOCK='rg\tcrate:ripgrep:rg\t15.2.0\n'

# run_main ARGS: build-tools.sh main with the stubs.
run_main() {
    btp "main --profile x86_64-v3 --out \"\$SANDBOX/out\" $*"
}

# cached_rg: path of rg 15.2.0 in the tool cache for the current recipe.
cached_rg() {
    local hash
    hash="$(PATH="$STUBS:$PATH" "$BASH_BIN" -c "source '$BUILD_TOOLS'; load_profile x86_64-v3; load_tools; recipe_hash rg")"
    echo "$XDG_CACHE_HOME/zsh-portable/tools/x86_64-v3/rg/15.2.0-$hash/rg"
}

test_verify_rejects_wrong_arch() {
    main_stubs "$RG_ONLY"
    make_elf aarch64 "$SANDBOX/bin"
    btp "load_profile x86_64-v3; verify_binary '$SANDBOX/bin'"
    [[ $STATUS -ne 0 ]] || fail "aarch64 binary accepted for x86_64-v3"
    make_elf x86_64 "$SANDBOX/bin"
    btp "load_profile x86_64-v3; verify_binary '$SANDBOX/bin'"
    assert_eq "$STATUS" 0
}

test_verify_rejects_dynamic_for_x86_64_v3() {
    main_stubs "$RG_ONLY"
    make_elf x86_64 "$SANDBOX/bin"
    STUB_READELF_INTERP=1 btp "load_profile x86_64-v3; verify_binary '$SANDBOX/bin'"
    [[ $STATUS -ne 0 ]] || fail "dynamic binary accepted for a static profile"
    [[ $OUTPUT == *"not static"* ]] || fail "no reason: $OUTPUT"
    return 0
}

test_verify_rejects_glibc_above_2_39_for_qos() {
    main_stubs "$RG_ONLY"
    make_elf aarch64 "$SANDBOX/bin"
    STUB_READELF_INTERP=1 STUB_READELF_GLIBC="2.17 2.39" btp "load_profile qos-orin; verify_binary '$SANDBOX/bin'"
    assert_eq "$STATUS" 0
    STUB_READELF_INTERP=1 STUB_READELF_GLIBC="2.17 2.41" btp "load_profile qos-orin; verify_binary '$SANDBOX/bin'"
    [[ $STATUS -ne 0 ]] || fail "GLIBC_2.41 accepted for glibc 2.39"
    [[ $OUTPUT == *"GLIBC_2.41"* ]] || fail "no reason: $OUTPUT"
    return 0
}

test_built_tool_lands_in_out_and_cache() {
    main_stubs "$RG_ONLY" "$RG_LOCK"
    crate_fixture ripgrep 15.2.0
    run_main
    assert_eq "$STATUS" 0
    [[ -x $SANDBOX/out/bin/rg ]] || fail "no out/bin/rg: $OUTPUT"
    [[ -x $(cached_rg) ]] || fail "not cached"
    return 0
}

test_cache_hit_skips_build() {
    main_stubs "$RG_ONLY" "$RG_LOCK"
    crate_fixture ripgrep 15.2.0
    run_main
    : >"$STUB_LOG"
    run_main
    assert_eq "$STATUS" 0
    grep -q '^cargo ' "$STUB_LOG" && fail "rebuilt despite a cache hit"
    [[ -x $SANDBOX/out/bin/rg ]] || fail "no out/bin/rg"
    return 0
}

# build-tools.sh's own settings (LTO, strip, Go flags) are part of the cache
# key, so changing them rebuilds instead of reusing old binaries.
test_build_settings_in_recipe_hash() {
    main_stubs "$RG_ONLY"
    btp 'load_profile x86_64-v3; load_tools; a=$(recipe_hash rg); BUILD_SETTINGS+=" changed"; b=$(recipe_hash rg); [[ $a != "$b" ]] && echo differs'
    assert_eq "$OUTPUT" "differs"
}

test_recipe_change_rebuilds() {
    main_stubs "$RG_ONLY" "$RG_LOCK"
    crate_fixture ripgrep 15.2.0
    run_main
    printf '%s\n' 'rg  BurntSushi/ripgrep  rg  musl|gnu  crate:ripgrep:rg:--features=pcre2' >"$TOOLS_FILE"
    : >"$STUB_LOG"
    run_main
    grep -q '^cargo zigbuild.*--features=pcre2' "$STUB_LOG" || fail "changed recipe not rebuilt: $(cat "$STUB_LOG")"
    return 0
}

# Review Focus 3: --locked with everything cached needs no network.
test_locked_full_cache_works_offline() {
    main_stubs "$RG_ONLY" "$RG_LOCK"
    local c
    c="$(cached_rg)"
    mkdir -p "$(dirname "$c")"
    make_elf x86_64 "$c"
    STUB_CURL_FAIL=http STUB_CARGO_FAIL=1 STUB_EGET_FAIL=1 run_main --locked
    assert_eq "$STATUS" 0
    [[ -x $SANDBOX/out/bin/rg ]] || fail "not taken from the cache"
    grep -qE '^(curl|cargo|go|eget) ' "$STUB_LOG" && fail "network or build used: $(cat "$STUB_LOG")"
    return 0
}

# Review Focus 5: a failed (or killed) build never becomes a cache entry.
test_failed_build_never_cached() {
    main_stubs "$RG_ONLY" "$RG_LOCK"
    crate_fixture ripgrep 15.2.0
    STUB_CARGO_FAIL=1 STUB_EGET_FAIL=1 run_main
    [[ -e $(cached_rg) ]] && fail "failed build cached"
    : >"$STUB_LOG"
    run_main
    grep -q '^cargo zigbuild' "$STUB_LOG" || fail "not rebuilt after the failure"
    [[ -x $(cached_rg) ]] || fail "good build not cached"
    return 0
}

test_unverified_build_never_cached() {
    main_stubs "$RG_ONLY" "$RG_LOCK"
    crate_fixture ripgrep 15.2.0
    STUB_ELF_ARCH=aarch64 run_main
    [[ -e $(cached_rg) ]] && fail "wrong-arch build cached"
    return 0
}

test_failed_build_uses_newest_cached_version() {
    main_stubs "$RG_ONLY" "$RG_LOCK"
    crate_fixture ripgrep 15.2.0
    run_main
    printf 'rg\tcrate:ripgrep:rg\t15.3.0\n' >"$LOCKS_DIR/x86_64-v3.lock"
    crate_fixture ripgrep 15.3.0
    STUB_CARGO_FAIL=1 run_main
    assert_eq "$STATUS" 0
    grep -qP '^rg\tcrate:ripgrep:rg\t15.2.0\t[0-9a-f]{64}\tfallback-cache$' "$SANDBOX/out/tools.lock" ||
        fail "tools.lock: $(cat "$SANDBOX/out/tools.lock")"
    return 0
}

test_failed_build_without_cache_uses_release() {
    main_stubs "$RG_ONLY" "$RG_LOCK"
    crate_fixture ripgrep 15.2.0
    STUB_CARGO_FAIL=1 run_main
    assert_eq "$STATUS" 0
    grep -q "^eget .*BurntSushi/ripgrep$" "$STUB_LOG" || fail "no release fallback: $(cat "$STUB_LOG")"
    grep -q $'^rg\tcrate:ripgrep:rg\t' "$SANDBOX/out/tools.lock" || fail "not in tools.lock"
    grep -q $'\tfallback-release$' "$SANDBOX/out/tools.lock" || fail "how: $(cat "$SANDBOX/out/tools.lock")"
    [[ -x $SANDBOX/out/bin/rg ]] || fail "no binary"
    return 0
}

# Upstream release binaries are used as published (some only ship glibc
# builds); the static/glibc checks are for binaries built here.
test_release_source_is_not_required_static() {
    main_stubs 'lnav  tstack/lnav  lnav  musl  release' 'lnav\trelease\tv0.14.1\n'
    STUB_READELF_INTERP=1 run_main
    assert_eq "$STATUS" 0
    grep -qP '^lnav\trelease\tv0.14.1\t[0-9a-f]{64}\tbuilt$' "$SANDBOX/out/tools.lock" ||
        fail "tools.lock: $(cat "$SANDBOX/out/tools.lock")"
    return 0
}

test_tool_with_nothing_is_reported_and_skipped() {
    main_stubs "$TWO_TOOLS" 'rg\tcrate:ripgrep:rg\t15.2.0\nfzf\tgo:github.com/junegunn/fzf\tv0.66.0\n'
    crate_fixture ripgrep 15.2.0
    STUB_CARGO_FAIL=1 STUB_EGET_FAIL=1 run_main
    assert_eq "$STATUS" 0
    [[ $OUTPUT == *"rg: no build"* ]] || fail "not reported: $OUTPUT"
    [[ -e $SANDBOX/out/bin/rg ]] && fail "rg present"
    [[ -x $SANDBOX/out/bin/fzf ]] || fail "fzf missing"
    grep -q '^rg' "$SANDBOX/out/tools.lock" && fail "rg in tools.lock"
    return 0
}

test_tools_lock_lists_sha256_and_how() {
    main_stubs "$RG_ONLY" "$RG_LOCK"
    crate_fixture ripgrep 15.2.0
    run_main
    local sum
    sum="$(sha256sum "$SANDBOX/out/bin/rg" | cut -d' ' -f1)"
    assert_eq "$(grep -v '^#' "$SANDBOX/out/tools.lock")" "rg	crate:ripgrep:rg	15.2.0	$sum	built"
    run_main
    assert_eq "$(grep -v '^#' "$SANDBOX/out/tools.lock")" "rg	crate:ripgrep:rg	15.2.0	$sum	cached"
}

test_only_limits_tools() {
    main_stubs "$TWO_TOOLS" 'rg\tcrate:ripgrep:rg\t15.2.0\nfzf\tgo:github.com/junegunn/fzf\tv0.66.0\n'
    run_main --only fzf
    [[ -x $SANDBOX/out/bin/fzf ]] || fail "no fzf"
    [[ -e $SANDBOX/out/bin/rg ]] && fail "rg built"
    return 0
}

# main runs under set -e: a last tools.tsv row outside --only must not end it.
test_only_without_the_last_row() {
    main_stubs "$TWO_TOOLS" 'rg\tcrate:ripgrep:rg\t15.2.0\nfzf\tgo:github.com/junegunn/fzf\tv0.66.0\n'
    crate_fixture ripgrep 15.2.0
    run_main --only rg
    assert_eq "$STATUS" 0
    [[ -x $SANDBOX/out/bin/rg ]] || fail "no rg: $OUTPUT"
    return 0
}

# --resolve keeps the old lock entry for a tool that fails at the new version.
test_resolve_keeps_old_entry_when_new_build_fails() {
    main_stubs "$RG_ONLY" "$RG_LOCK"
    fixture https://crates.io/api/v1/crates/ripgrep '{"crate":{"max_stable_version":"15.3.0"}}'
    crate_fixture ripgrep 15.3.0
    STUB_CARGO_FAIL=1 run_main --resolve
    assert_eq "$STATUS" 0
    grep -qx $'rg\tcrate:ripgrep:rg\t15.2.0' "$LOCKS_DIR/x86_64-v3.lock" || fail "lock: $(cat "$LOCKS_DIR/x86_64-v3.lock")"
    return 0
}

test_resolve_writes_new_version_when_build_works() {
    main_stubs "$RG_ONLY" "$RG_LOCK"
    fixture https://crates.io/api/v1/crates/ripgrep '{"crate":{"max_stable_version":"15.3.0"}}'
    crate_fixture ripgrep 15.3.0
    run_main --resolve
    grep -qx $'rg\tcrate:ripgrep:rg\t15.3.0' "$LOCKS_DIR/x86_64-v3.lock" || fail "lock: $(cat "$LOCKS_DIR/x86_64-v3.lock")"
    return 0
}

test_locked_never_writes_lock() {
    main_stubs "$TWO_TOOLS" "$RG_LOCK"
    crate_fixture ripgrep 15.2.0
    fixture https://proxy.golang.org/github.com/junegunn/fzf/@latest '{"Version":"v0.66.0"}'
    run_main --locked
    assert_eq "$(cat "$LOCKS_DIR/x86_64-v3.lock")" "$(printf "$RG_LOCK")"
}

# ---------------------------------------------------------------------------
# Builder image and runner
# ---------------------------------------------------------------------------

FEATURE_DIR="$REPO_DIR/features/src/zsh-builder"
BUILDER="$REPO_DIR/portable/builder.sh"

test_feature_json_valid() {
    OUTPUT="$(python3 - "$FEATURE_DIR/devcontainer-feature.json" <<'EOF'
import json, sys
f = json.load(open(sys.argv[1]))
print(f["id"], f["version"], f["options"]["rustTargets"]["default"], f["options"]["goVersion"]["default"])
EOF
)"
    assert_eq "$OUTPUT" "zsh-builder 0.1.0 x86_64-unknown-linux-musl,aarch64-unknown-linux-gnu latest"
}

# The Dockerfile route doesn't apply containerEnv, so it sets the same ENV.
test_dockerfile_env_matches_feature() {
    local key value
    while IFS=$'\t' read -r key value; do
        grep -qxF "ENV $key=\"$value\"" "$REPO_DIR/features/builder/x86_64.Dockerfile" ||
            fail "Dockerfile lacks ENV $key=\"$value\""
    done < <(python3 -c 'import json,sys; [print(k+"\t"+v) for k,v in json.load(open(sys.argv[1]))["containerEnv"].items()]' \
        "$FEATURE_DIR/devcontainer-feature.json")
    return 0
}

test_feature_install_script_syntax() {
    bash -n "$FEATURE_DIR/install.sh" || fail "install.sh syntax"
    [[ -x $FEATURE_DIR/install.sh ]] || fail "install.sh not executable"
    return 0
}

# docker_stub: docker that logs one argument per line.
docker_stub() {
    stubs_setup
    printf '#!/usr/bin/env bash\nprintf "%%s\\n" docker "$@" >>"$STUB_LOG"\n' >"$STUBS/docker"
    chmod +x "$STUBS/docker"
}

test_builder_image_builds_dockerfile() {
    docker_stub
    PATH="$STUBS:$PATH" "$BASH_BIN" "$BUILDER" image >/dev/null 2>&1
    assert_eq "$(tr '\n' ' ' <"$STUB_LOG")" "docker build -f $REPO_DIR/features/builder/x86_64.Dockerfile -t zsh-builder:local $REPO_DIR "
}

test_builder_run_mounts_repo_and_cache() {
    docker_stub
    local cache="$SANDBOX/xdg/zsh-portable"
    XDG_CACHE_HOME="$SANDBOX/xdg" PATH="$STUBS:$PATH" "$BASH_BIN" "$BUILDER" run echo hi >/dev/null 2>&1
    local log
    log="$(tr '\n' ' ' <"$STUB_LOG")"
    [[ -d $cache ]] || fail "cache dir not created"
    local want
    for want in "docker run --rm" "--user $(id -u):$(id -g)" "-v $REPO_DIR:/src" "-w /src" \
        "-v $cache:$cache" "-e ZSH_PORTABLE_CACHE=$cache" "-e XDG_CACHE_HOME=$cache/xdg-cache" "-e HOME=$cache/home" \
        "-e CARGO_HOME=$cache/cargo-home" "-e ZIG_GLOBAL_CACHE_DIR=$cache/zig" \
        "zsh-builder:local echo hi"; do
        [[ $log == *"$want "* ]] || fail "missing '$want' in: $log"
    done
    return 0
}

# Inside the builder XDG_CACHE_HOME is a writable dir in the mounted cache
# (cargo-zigbuild, go and friends write there); ZSH_PORTABLE_CACHE keeps
# build-tools.sh on the host's cache path.
test_cache_root_override() {
    OUTPUT="$(XDG_CACHE_HOME=/x ZSH_PORTABLE_CACHE=/y/zp "$BASH_BIN" -c "source '$BUILD_TOOLS'; echo \$CACHE_ROOT")"
    assert_eq "$OUTPUT" "/y/zp"
    OUTPUT="$(XDG_CACHE_HOME=/x "$BASH_BIN" -c "unset ZSH_PORTABLE_CACHE; source '$BUILD_TOOLS'; echo \$CACHE_ROOT")"
    assert_eq "$OUTPUT" "/x/zsh-portable"
}

# The token comes from the host (env, secrets file or gh) like for eget, and
# reaches the container by name only (never on the docker command line).
test_builder_run_passes_github_token_from_secrets() {
    docker_stub
    mkdir -p "$SANDBOX/cfg/secrets"
    printf 'EGET_GITHUB_TOKEN=s3cret\n' >"$SANDBOX/cfg/secrets/env"
    printf '#!/usr/bin/env bash\nprintf "%%s\\n" docker "$@" >>"$STUB_LOG"\necho "token=$EGET_GITHUB_TOKEN" >>"$STUB_LOG"\n' >"$STUBS/docker"
    env -u EGET_GITHUB_TOKEN XDG_CONFIG_HOME="$SANDBOX/cfg" XDG_CACHE_HOME="$SANDBOX/xdg" PATH="$STUBS:$PATH" \
        "$BASH_BIN" "$BUILDER" run true >/dev/null 2>&1
    grep -qx -- "EGET_GITHUB_TOKEN" "$STUB_LOG" || fail "token not passed: $(tr '\n' ' ' <"$STUB_LOG")"
    grep -qx "token=s3cret" "$STUB_LOG" || fail "token not in docker's env"
    grep -q "s3cret" <(grep -v '^token=' "$STUB_LOG") && fail "token on the command line"
    return 0
}

test_builder_usage() {
    OUTPUT="$("$BASH_BIN" "$BUILDER" 2>&1)"
    STATUS=$?
    assert_eq "$STATUS" 2
    [[ $OUTPUT == *Usage* ]] || fail "no usage: $OUTPUT"
    return 0
}

# BUILDER_E2E=1: the real image, and a real x86_64-v3 build of rg and fzf.
test_e2e_x86_64_v3_builds_rg_and_fzf() {
    [[ -n ${BUILDER_E2E:-} ]] || return 0
    "$BASH_BIN" "$BUILDER" image >"$SANDBOX/image.log" 2>&1 || { fail "image build: $(tail -5 "$SANDBOX/image.log")"; return; }
    local cache="${XDG_CACHE_HOME:-$HOME/.cache}/zsh-portable" out
    out="$cache/e2e-out"
    rm -rf "$out" "$cache/e2e-locks"
    "$BASH_BIN" "$BUILDER" run env LOCKS_DIR="$cache/e2e-locks" \
        portable/build-tools.sh --profile x86_64-v3 --resolve --only rg,fzf --out "$out" \
        >"$SANDBOX/build.log" 2>&1 || { fail "build: $(tail -20 "$SANDBOX/build.log")"; return; }
    local t
    for t in rg fzf; do
        [[ $("$BASH_BIN" -c "source '$REPO_DIR/portable/lib.sh'; resolve_chezmoi_src; elf_arch '$out/bin/$t'") == x86_64 ]] || fail "$t: not x86_64"
        readelf -lW "$out/bin/$t" | grep -q INTERP && fail "$t: not static"
        "$out/bin/$t" --version >/dev/null 2>&1 || fail "$t: doesn't run"
        grep -qP "^$t\t.*\t(built|cached)$" "$out/tools.lock" || fail "$t: tools.lock: $(cat "$out/tools.lock")"
    done
    return 0
}

# ---------------------------------------------------------------------------
# Final review fixes
# ---------------------------------------------------------------------------

# Important 1: the GitHub token never reaches build scripts (cargo build.rs,
# proc-macros, go, cross recipes), only curl and eget.
test_token_not_exported_to_builds() {
    main_stubs "$TWO_TOOLS" 'rg\tcrate:ripgrep:rg\t15.2.0\nfzf\tgo:github.com/junegunn/fzf\tv0.66.0\n'
    crate_fixture ripgrep 15.2.0
    sed -i '2a echo "cargo-token=${EGET_GITHUB_TOKEN:-}" >>"$STUB_LOG"' "$STUBS/cargo"
    sed -i '2a echo "go-token=${EGET_GITHUB_TOKEN:-}" >>"$STUB_LOG"' "$STUBS/go"
    EGET_GITHUB_TOKEN=s3cret run_main
    grep -qx "cargo-token=" "$STUB_LOG" || fail "cargo saw the token: $(grep token "$STUB_LOG")"
    grep -qx "go-token=" "$STUB_LOG" || fail "go saw the token: $(grep token "$STUB_LOG")"
    return 0
}

# Minor 1 (regraded): the token isn't on curl's command line.
test_token_not_on_curl_command_line() {
    stubs_setup
    fixture https://api.github.com/repos/tstack/lnav/releases/latest '{"tag_name":"v0.14.1"}'
    EGET_GITHUB_TOKEN=s3cret btp 'latest_version release tstack/lnav'
    assert_eq "$OUTPUT" "v0.14.1"
    grep -q s3cret "$SANDBOX/curl-args.log" && fail "token in curl args: $(cat "$SANDBOX/curl-args.log")"
    return 0
}

# Important 2: a lock entry written for another recipe is looked up again.
test_lock_entry_for_other_source_is_resolved() {
    stubs_setup
    use_tools 'zellij  zellij-org/zellij  zellij  musl  release'
    printf 'zellij\tcrate:zellij\t0.43.1\n' >"$LOCKS_DIR/x86_64-v3.lock"
    fixture https://api.github.com/repos/zellij-org/zellij/releases/latest '{"tag_name":"v0.45.1"}'
    btp 'load_profile x86_64-v3; resolve_versions locked; echo "${LOCK[zellij]}"'
    assert_eq "$OUTPUT" "v0.45.1"
}

# Important 3: a GitHub failure (not "no releases") fails the go lookup, so
# --resolve keeps the old entry instead of locking a pseudo-version.
test_go_pseudo_version_github_failure_fails_lookup() {
    stubs_setup
    fixture https://proxy.golang.org/github.com/!lifailon/lazyjournal/@latest '{"Version":"v0.0.0-20261026112250-ca677bc44ea2"}'
    STUB_CURL_FAIL=api.github.com btp 'latest_version go:github.com/Lifailon/lazyjournal Lifailon/lazyjournal'
    [[ $STATUS -ne 0 ]] || fail "lookup succeeded with: $OUTPUT"
    return 0
}

# Important 4: cross recipes' scripts are part of their cache key.
test_cross_script_in_recipe_hash() {
    main_stubs 'tmux  cross:tmux  tmux  -  cross:tmux'
    printf 'TMUX_VERSION=3.5a\n' >"$CROSS_DIR/tmux.sh"
    btp 'load_profile qos-orin; load_tools; recipe_hash tmux'
    local a=$OUTPUT
    printf 'TMUX_VERSION=3.6\n' >"$CROSS_DIR/tmux.sh"
    btp 'load_profile qos-orin; load_tools; recipe_hash tmux'
    [[ -n $a && $a != "$OUTPUT" ]] || fail "hash unchanged: $a"
    return 0
}

# Important 5: --out never deletes a bin/ that build-tools didn't make.
test_out_with_foreign_bin_is_refused() {
    main_stubs "$RG_ONLY" "$RG_LOCK"
    crate_fixture ripgrep 15.2.0
    mkdir -p "$SANDBOX/out/bin"
    printf 'mine\n' >"$SANDBOX/out/bin/chezmoi"
    run_main
    [[ $STATUS -ne 0 ]] || fail "accepted a foreign bin/"
    [[ -f $SANDBOX/out/bin/chezmoi ]] || fail "deleted a foreign file"
    [[ $OUTPUT == *"not a build-tools output"* ]] || fail "no reason: $OUTPUT"
    return 0
}

# Important 5: bin/ and tools.lock change together, at the end of the run.
test_out_replaced_only_when_done() {
    main_stubs "$RG_ONLY" "$RG_LOCK"
    crate_fixture ripgrep 15.2.0
    run_main
    local before
    before="$(cat "$SANDBOX/out/tools.lock")"
    # A run that dies mid-way (here: lock unreadable after the tools are
    # chosen) leaves the previous output alone.
    sed -i '2a [[ -n ${STUB_DIE:-} ]] && kill -9 $PPID' "$STUBS/eget"
    printf '%s\n' 'lnav  tstack/lnav  lnav  musl  release' >"$TOOLS_FILE"
    printf 'lnav\trelease\tv1\n' >"$LOCKS_DIR/x86_64-v3.lock"
    STUB_DIE=1 run_main
    assert_eq "$(cat "$SANDBOX/out/tools.lock")" "$before"
    [[ -x $SANDBOX/out/bin/rg ]] || fail "previous bin/ wiped by a run that didn't finish"
    [[ -e $SANDBOX/out/bin/lnav ]] && fail "half-filled bin/ published"
    return 0
}

# Minor 9 (plan requirement): login shells keep the toolchains on PATH.
test_feature_adds_profile_d() {
    grep -q '/etc/profile.d/zsh-builder.sh' "$FEATURE_DIR/install.sh" || fail "no /etc/profile.d/zsh-builder.sh"
    return 0
}

# ---------------------------------------------------------------------------

for t in $(declare -F | awk '{print $3}' | grep '^test_'); do
    run_test "$t"
done

echo
echo "$PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
