#!/usr/bin/env bash
#
# Tests for portable/static/: static musl builds from source (static:NAME
# rows in the app manifest).
#
# docker, curl and zig are stubs on a sandboxed PATH, so nothing is
# downloaded or built. STATIC_E2E=1 adds real builds of every static/*.sh
# recipe for x86_64, aarch64 and armv7l in the builder image, run in a bare
# debian:12 container (arm through qemu binfmt, when registered).

set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATIC_LIB="$REPO_DIR/portable/static/lib.sh"
BASH_BIN="$(command -v bash)"
PASS=0
FAIL=0

setup() {
    SANDBOX="$(mktemp -d)"
    STUBS="$SANDBOX/stubs"
    STUB_LOG="$SANDBOX/calls.log"
    export SANDBOX STUBS STUB_LOG
    mkdir -p "$STUBS"
    : >"$STUB_LOG"
    local tool
    for tool in cat chmod chown cp cut dirname grep head id install mkdir mktemp mv nproc readelf rm sed sh sha256sum tail tar tr; do
        ln -s "$(command -v "$tool")" "$STUBS/$tool"
    done
    unset STATIC_IMAGE STATIC_NATIVE STATIC_TOOLS STATIC_ALPINE STATIC_APK XDG_CACHE_HOME
    export ZSH_PORTABLE_CACHE="$SANDBOX/cache"
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

assert_output_matches() {
    grep -Eq -- "$1" <<<"$OUTPUT" || fail "output does not match: $1
$OUTPUT"
}

run_test() {
    CURRENT="$1"
    setup
    local before=$FAIL
    "$1"
    [[ $FAIL -eq $before ]] && PASS=$((PASS + 1)) && echo "  ok   $1"
    teardown
}

# stub NAME BODY: an executable on the sandboxed PATH.
stub() {
    rm -f "$STUBS/$1"
    printf '#!%s\n%s\n' "$BASH_BIN" "$2" >"$STUBS/$1"
    chmod +x "$STUBS/$1"
}

# sl CODE: run CODE in bash on the sandboxed PATH after sourcing static/lib.sh.
sl() {
    OUTPUT="$(PATH="$STUBS" "$BASH_BIN" -c "set -euo pipefail; source '$STATIC_LIB'; $1" 2>&1)"
    STATUS=$?
}

# static_elf FILE: copy a statically linked ELF (built by the host's zig or
# found on the host) to FILE; skip the caller if there is none.
STATIC_ELF=""
find_static_elf() {
    local f
    for f in /usr/bin/busybox /bin/busybox "$(command -v ldconfig 2>/dev/null)" /sbin/ldconfig; do
        [[ -f $f ]] && ! readelf -lW "$f" 2>/dev/null | grep -q INTERP && readelf -h "$f" >/dev/null 2>&1 \
            && { STATIC_ELF=$f; return 0; }
    done
    return 1
}

# ---------------------------------------------------------------------------
# Targets and sources
# ---------------------------------------------------------------------------

test_target_per_arch() {
    sl 'for a in x86_64 aarch64 armv7l; do static_target $a; done'
    assert_eq "$OUTPUT" "x86_64-linux-musl
aarch64-linux-musl
arm-linux-musleabihf"
}

test_target_unknown_arch_fails() {
    sl 'static_target riscv64'
    [[ $STATUS -ne 0 ]] || fail "riscv64 accepted"
    assert_output_matches "no static build for riscv64"
}

stub_curl() {
    stub curl 'echo "curl $*" >>"$STUB_LOG"
while (( $# )); do [[ $1 == -o ]] && out=$2; shift; done
printf "source\n" >"$out"'
}

SOURCE_SHA=$(printf 'source\n' | sha256sum | cut -d' ' -f1)

test_fetch_downloads_once() {
    stub_curl
    sl "static_fetch t.tar.gz https://example.com/t.tar.gz $SOURCE_SHA; static_fetch t.tar.gz https://example.com/t.tar.gz $SOURCE_SHA"
    assert_eq "$STATUS" 0
    assert_eq "$(grep -c '^curl' "$STUB_LOG")" 1
    assert_eq "$(cat "$SANDBOX/cache/static-src/t.tar.gz")" source
}

test_fetch_rejects_bad_checksum() {
    stub_curl
    sl 'static_fetch t.tar.gz https://example.com/t.tar.gz 0000'
    [[ $STATUS -ne 0 ]] || fail "bad checksum accepted"
    assert_output_matches "checksum mismatch for t.tar.gz"
    [[ ! -e $SANDBOX/cache/static-src/t.tar.gz ]] || fail "bad download kept"
}

test_fetch_rechecks_cached_source() {
    stub_curl
    mkdir -p "$SANDBOX/cache/static-src"
    echo tampered >"$SANDBOX/cache/static-src/t.tar.gz"
    sl "static_fetch t.tar.gz https://example.com/t.tar.gz $SOURCE_SHA"
    assert_eq "$STATUS" 0
    assert_eq "$(cat "$SANDBOX/cache/static-src/t.tar.gz")" source
}

# ---------------------------------------------------------------------------
# Running a build
# ---------------------------------------------------------------------------

test_native_run_gets_environment() {
    find_static_elf || { echo "  skip $CURRENT (no static ELF on host)"; return 0; }
    sl "STATIC_NATIVE=1 static_run aarch64 '$SANDBOX/out/tool' FOO=bar <<'EOF'
printf '%s|' \"\$TARGET\" \"\$CC\" \"\$AR\" \"\$SRC\" \"\$FOO\" \"\$JOBS\" >&2
[[ \$PWD != '$PWD' ]] || exit 9
cp '$STATIC_ELF' \"\$OUT_FILE\"
EOF"
    assert_eq "$STATUS" 0
    assert_output_matches "^aarch64-linux-musl\|zig cc -target aarch64-linux-musl\|zig ar\|$SANDBOX/cache/static-src\|bar\|[0-9]+\|"
    [[ -x $SANDBOX/out/tool ]] || fail "no output"
}

test_run_rejects_dynamic_binary() {
    sl "STATIC_NATIVE=1 static_run x86_64 '$SANDBOX/out/tool' <<'EOF'
cp \"\$(PATH=/usr/bin:/bin command -v ls)\" \"\$OUT_FILE\"
EOF"
    [[ $STATUS -ne 0 ]] || fail "dynamic binary accepted"
    assert_output_matches "not statically linked"
    [[ ! -e $SANDBOX/out/tool ]] || fail "dynamic binary kept"
}

test_run_fails_when_script_fails() {
    sl "STATIC_NATIVE=1 static_run x86_64 '$SANDBOX/out/tool' <<'EOF'
exit 3
EOF"
    [[ $STATUS -ne 0 ]] || fail "failure ignored"
    [[ ! -e $SANDBOX/out/tool ]] || fail "output left"
}

test_quiet_shows_log_tail_on_failure() {
    sl "STATIC_NATIVE=1 static_run x86_64 '$SANDBOX/out/tool' <<'EOF'
quiet sh -c 'echo hidden-ok; echo boom >&2; exit 1'
EOF"
    [[ $STATUS -ne 0 ]] || fail "failure ignored"
    assert_output_matches "boom"
}

test_native_needs_static_tools() {
    sl "STATIC_NATIVE=1 STATIC_TOOLS=bison static_run x86_64 '$SANDBOX/out/tool' </dev/null"
    [[ $STATUS -ne 0 ]] || fail "missing bison accepted"
    assert_output_matches "needs bison"
}

stub_docker() {
    stub docker 'echo "docker $*" >>"$STUB_LOG"; cat >"$SANDBOX/docker-stdin"'
}

test_docker_run_mounts_and_env() {
    stub_docker
    stub id 'case $1 in -u) echo 1234 ;; -g) echo 99 ;; esac'
    sl "STATIC_NATIVE=0 STATIC_TOOLS=bison static_run aarch64 '$SANDBOX/out/tool' FOO=bar <<'EOF'
echo the-recipe
EOF"
    local call
    call="$(grep '^docker' "$STUB_LOG")"
    [[ $call == "docker run --rm -i "* ]] || fail "not docker run: $call"
    [[ $call == *"-v $SANDBOX/cache/static-src:/src:ro"* ]] || fail "no source mount: $call"
    [[ $call == *"-v $SANDBOX/out:/out"* ]] || fail "no output mount: $call"
    [[ $call == *"-e TARGET=aarch64-linux-musl"* ]] || fail "no TARGET: $call"
    [[ $call == *"-e FOO=bar"* ]] || fail "no FOO: $call"
    [[ $call == *"-e OUT_FILE=/out/tool"* ]] || fail "no OUT_FILE: $call"
    [[ $call == *"-e STATIC_TOOLS=bison"* ]] || fail "no STATIC_TOOLS: $call"
    [[ $call == *"-e OWNER=1234:99"* ]] || fail "no OWNER: $call"
    [[ $call == *" ghcr.io/jordanbradshaw/zsh-builder:latest bash -c "* ]] || fail "image: $call"
    grep -q '^echo the-recipe$' "$SANDBOX/docker-stdin" || fail "recipe not on stdin"
}

test_docker_image_override() {
    stub_docker
    sl "STATIC_NATIVE=0 STATIC_IMAGE=zsh-builder:local static_run x86_64 '$SANDBOX/out/tool' </dev/null"
    grep -q ' zsh-builder:local bash -c ' "$STUB_LOG" || fail "image not overridden: $(cat "$STUB_LOG")"
}

test_auto_mode_prefers_native_zig() {
    stub_docker
    find_static_elf || { echo "  skip $CURRENT (no static ELF on host)"; return 0; }
    stub zig 'exit 0'
    stub bison 'exit 0'
    sl "STATIC_TOOLS=bison static_run x86_64 '$SANDBOX/out/tool' <<'EOF'
cp '$STATIC_ELF' \"\$OUT_FILE\"
EOF"
    assert_eq "$STATUS" 0
    grep -q '^docker' "$STUB_LOG" && fail "docker used despite zig and bison"
    return 0
}

test_auto_mode_uses_docker_without_tools() {
    stub_docker
    stub zig 'exit 0'
    sl "STATIC_TOOLS=bison static_run x86_64 '$SANDBOX/out/tool' </dev/null"
    grep -q '^docker run' "$STUB_LOG" || fail "docker not used without bison"
}

# Recipes needing a native musl toolchain (below: Rust plus Alpine's static
# libelf) run in rust:alpine for the target platform, never natively.
test_alpine_run_uses_target_platform() {
    stub_docker
    stub zig 'exit 0'
    sl "STATIC_NATIVE=1 STATIC_ALPINE=1 STATIC_APK='clang llvm' static_run aarch64 '$SANDBOX/out/tool' FOO=bar <<'EOF'
echo the-recipe
EOF"
    local call
    call="$(cat "$STUB_LOG")"
    [[ $call == *"--platform linux/arm64"* ]] || fail "no platform: $call"
    [[ $call == *" rust:"*"-alpine"*" sh -c "* ]] || fail "not rust alpine: $call"
    [[ $call == *"apk add"*"bash binutils clang llvm"* ]] || fail "no apk add: $call"
    [[ $call == *"-e FOO=bar"* && $call == *"-e OUT_FILE=/out/tool"* ]] || fail "env: $call"
    [[ $call != *"-e CC="* ]] || fail "zig CC passed to Alpine: $call"
    grep -q '^echo the-recipe$' "$SANDBOX/docker-stdin" || fail "recipe not on stdin"
}

test_alpine_platforms() {
    sl 'static_platform x86_64; static_platform aarch64; static_platform armv7l'
    assert_eq "$OUTPUT" "linux/amd64
linux/arm64
linux/arm/v7"
}

# ---------------------------------------------------------------------------
# Recipes
# ---------------------------------------------------------------------------

# Every recipe pins a version and a sha256 and uses the shared helpers.
test_recipes_pin_sources() {
    local r
    for r in "$REPO_DIR"/portable/static/*.sh; do
        [[ ${r##*/} == lib.sh || ${r##*/} == deps.sh ]] && continue
        grep -Eq '^[A-Z0-9_]+_VERSION=[0-9]' "$r" || fail "${r##*/}: no pinned version"
        grep -Eq '^[A-Z0-9_]+_SHA256=[0-9a-f]{64}$' "$r" || fail "${r##*/}: no sha256"
        grep -q 'static_fetch ' "$r" || fail "${r##*/}: no static_fetch"
        grep -q 'static_run ' "$r" || fail "${r##*/}: no static_run"
        [[ -x $r ]] || fail "${r##*/}: not executable"
    done
    for r in ss nstat lsof nethogs iftop below; do
        [[ -f $REPO_DIR/portable/static/$r.sh ]] || fail "missing recipe $r"
    done
}

# ss and nstat both come from iproute2: same pinned tarball.
test_iproute2_recipes_agree() {
    local a b
    a="$(grep -E '^IPROUTE2_(VERSION|SHA256)=' "$REPO_DIR/portable/static/ss.sh")"
    b="$(grep -E '^IPROUTE2_(VERSION|SHA256)=' "$REPO_DIR/portable/static/nstat.sh" 2>/dev/null)"
    [[ -n $a ]] || fail "ss.sh pins nothing"
    assert_eq "$b" "$a"
}

test_below_has_no_armv7l() {
    OUTPUT="$("$REPO_DIR/portable/static/below.sh" armv7l "$SANDBOX/below" 2>&1)"
    STATUS=$?
    [[ $STATUS -ne 0 ]] || fail "armv7l accepted"
    assert_output_matches "no static build for armv7l"
}

test_recipe_rejects_unknown_arch() {
    OUTPUT="$("$REPO_DIR/portable/static/lsof.sh" riscv64 "$SANDBOX/lsof" 2>&1)"
    STATUS=$?
    [[ $STATUS -ne 0 ]] || fail "riscv64 accepted"
    assert_output_matches "no static build for riscv64"
}

# ---------------------------------------------------------------------------
# Real builds (STATIC_E2E=1)
# ---------------------------------------------------------------------------

# e2e_check ARCH PLATFORM NAME ARGS...: build NAME for ARCH and run it with
# ARGS in a bare debian:12 for PLATFORM.
e2e_check() {
    local arch=$1 platform=$2 name=$3
    shift 3
    local out="$E2E_OUT/$arch/$name"
    if [[ ! -x $out ]]; then
        "$REPO_DIR/portable/static/$name.sh" "$arch" "$out" || { fail "$name $arch: build failed"; return; }
    fi
    readelf -lW "$out" | grep -q INTERP && fail "$name $arch: not static"
    # shellcheck disable=SC2086 # extra docker options
    docker run --rm ${E2E_DOCKER_ARGS:-} --platform "$platform" -v "$E2E_OUT/$arch:/t:ro" debian:12 "/t/$name" "$@" >"$SANDBOX/run.out" 2>&1 \
        || fail "$name $arch: '$name $*' failed: $(cat "$SANDBOX/run.out")"
    return 0
}

test_e2e_x86_64() {
    e2e_check x86_64 linux/amd64 ss -tln
    e2e_check x86_64 linux/amd64 lsof -v
    e2e_check x86_64 linux/amd64 lsof -p 1
    e2e_check x86_64 linux/amd64 nstat -V
    e2e_check x86_64 linux/amd64 nstat -az
    e2e_check x86_64 linux/amd64 nethogs -V
    e2e_check x86_64 linux/amd64 iftop -h
    E2E_DOCKER_ARGS="--cap-add NET_ADMIN --cap-add NET_RAW" e2e_check x86_64 linux/amd64 iftop -t -s 1 -n
    e2e_check x86_64 linux/amd64 below --help
}

test_e2e_aarch64() {
    if [[ ! -e /proc/sys/fs/binfmt_misc/qemu-aarch64 ]]; then
        echo "  skip $CURRENT (no qemu-aarch64 binfmt)"
        return 0
    fi
    # qemu-user has no netlink, so ss can only print its version.
    e2e_check aarch64 linux/arm64 ss -V
    e2e_check aarch64 linux/arm64 lsof -v
    e2e_check aarch64 linux/arm64 nstat -V
    e2e_check aarch64 linux/arm64 nethogs -V
    e2e_check aarch64 linux/arm64 iftop -h
    e2e_check aarch64 linux/arm64 below --help
}

test_e2e_armv7l() {
    if [[ ! -e /proc/sys/fs/binfmt_misc/qemu-arm ]]; then
        echo "  skip $CURRENT (no qemu-arm binfmt)"
        return 0
    fi
    e2e_check armv7l linux/arm/v7 ss -V
    e2e_check armv7l linux/arm/v7 lsof -v
    e2e_check armv7l linux/arm/v7 nstat -V
    e2e_check armv7l linux/arm/v7 nethogs -V
    e2e_check armv7l linux/arm/v7 iftop -h
}

# ---------------------------------------------------------------------------

for t in $(declare -F | awk '{print $3}' | grep '^test_'); do
    [[ $t == test_e2e_* && -z ${STATIC_E2E:-} ]] && continue
    if [[ $t == test_e2e_* ]]; then
        E2E_OUT=${E2E_OUT:-$(mktemp -d)}
    fi
    run_test "$t"
done
echo
echo "$PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
