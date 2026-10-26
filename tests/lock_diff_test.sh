#!/usr/bin/env bash
#
# Tests for portable/lock-diff.sh. Pure text processing; no network.

set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOCK_DIFF="$REPO_DIR/portable/lock-diff.sh"

PASS=0
FAIL=0
CURRENT=""

setup() {
    SANDBOX="$(mktemp -d)"
    OUTPUT=""
    STATUS=0
}

teardown() {
    rm -rf "$SANDBOX"
}

fail() {
    echo "  FAIL [$CURRENT]: $*"
    echo "    --- output ---"
    sed 's/^/    /' <<<"$OUTPUT"
    FAIL=$((FAIL + 1))
    return 1
}

assert_eq() {
    [[ $1 == "$2" ]] || fail "expected '$2', got '$1'"
}

# lock FILE ROW... : header plus tab-separated rows given as "a b c".
lock() {
    local f=$1 row
    shift
    printf '# header\n' >"$f"
    for row in "$@"; do
        # shellcheck disable=SC2086
        set -- $row
        printf '%s\t%s\t%s\n' "$1" "$2" "$3" >>"$f"
    done
}

# tools FILE ROW... : header plus "name source version sha256 how" rows.
tools() {
    local f=$1 row
    shift
    printf '# header\n' >"$f"
    for row in "$@"; do
        # shellcheck disable=SC2086
        set -- $row
        printf '%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" "$5" >>"$f"
    done
}

run() {
    OUTPUT="$(bash "$LOCK_DIFF" "$SANDBOX/old" "$SANDBOX/new" "$SANDBOX/tools" 2>&1)"
    STATUS=$?
}

run_test() {
    CURRENT="$1"
    setup
    local before=$FAIL
    "$1"
    [[ $FAIL -eq $before ]] && PASS=$((PASS + 1)) && echo "  ok   $1"
    teardown
}

test_changed_version() {
    lock "$SANDBOX/old" "fd gh:sharkdp/fd 10.1.0" "rg gh:BurntSushi/ripgrep 14.0.0"
    lock "$SANDBOX/new" "fd gh:sharkdp/fd 10.2.0" "rg gh:BurntSushi/ripgrep 14.0.0"
    tools "$SANDBOX/tools" "fd gh:sharkdp/fd 10.2.0 abc built" "rg gh:BurntSushi/ripgrep 14.0.0 def cached"
    run
    assert_eq "$OUTPUT" "- fd 10.1.0 → 10.2.0"
}

test_new_and_removed() {
    lock "$SANDBOX/old" "fd gh:sharkdp/fd 10.1.0" "gone gh:x/gone 1.0"
    lock "$SANDBOX/new" "fd gh:sharkdp/fd 10.1.0" "fresh gh:x/fresh 2.0"
    tools "$SANDBOX/tools" "fd gh:sharkdp/fd 10.1.0 abc built" "fresh gh:x/fresh 2.0 def built"
    run
    assert_eq "$OUTPUT" "- fresh (new) → 2.0
- gone 1.0 → (removed)"
}

test_fallbacks_listed() {
    lock "$SANDBOX/old" "fd gh:sharkdp/fd 10.1.0" "rg gh:x/rg 1"
    lock "$SANDBOX/new" "fd gh:sharkdp/fd 10.2.0" "rg gh:x/rg 1"
    tools "$SANDBOX/tools" "fd gh:sharkdp/fd 10.2.0 abc built" "rg gh:x/rg 1 def fallback-cache" "zz gh:x/zz 3 ghi fallback-release"
    run
    assert_eq "$OUTPUT" "- fd 10.1.0 → 10.2.0
### Not built
- rg (fallback-cache)
- zz (fallback-release)"
}

test_no_change_prints_nothing() {
    lock "$SANDBOX/old" "fd gh:sharkdp/fd 10.1.0"
    lock "$SANDBOX/new" "fd gh:sharkdp/fd 10.1.0"
    tools "$SANDBOX/tools" "fd gh:sharkdp/fd 10.1.0 abc fallback-cache"
    run
    assert_eq "$OUTPUT" ""
    assert_eq "$STATUS" 0
}

for t in test_changed_version test_new_and_removed test_fallbacks_listed test_no_change_prints_nothing; do
    run_test "$t"
done

echo
echo "$PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
