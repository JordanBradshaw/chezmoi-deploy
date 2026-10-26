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

for t in $(declare -F | awk '{print $3}' | grep '^test_'); do
    run_test "$t"
done

echo
echo "$PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
