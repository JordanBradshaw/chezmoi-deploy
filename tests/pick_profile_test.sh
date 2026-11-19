#!/usr/bin/env bash
#
# Tests for portable/pick-profile.sh: host facts (as zssh's probe reports
# them) to a build profile, or nothing.

set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PICK="$REPO_DIR/portable/pick-profile.sh"
PASS=0
FAIL=0
CURRENT=""

fail() {
    echo "  FAIL [$CURRENT]: $*"
    FAIL=$((FAIL + 1))
    return 1
}

# expect WANT FACT...: pick-profile.sh FACT... prints WANT and exits 0.
expect() {
    local want=$1 got status
    shift
    got="$(bash "$PICK" "$@" 2>&1)"
    status=$?
    [[ $status -eq 0 ]] || fail "exit $status for $*: $got"
    [[ $got == "$want" ]] || fail "expected '$want' for $*, got '$got'"
}

run_test() {
    CURRENT="$1"
    local before=$FAIL
    "$1"
    [[ $FAIL -eq $before ]] && PASS=$((PASS + 1)) && echo "  ok   $1"
}

X86_FLAGS="fpu vme de pse tsc msr pae mce cx8 apic sse sse2 ssse3 fma cx16 sse4_1 sse4_2 avx f16c avx2 bmi1 bmi2"

test_jetson_is_qos_orin() {
    expect qos-orin arch=aarch64 cpu_part=0xd42 glibc=2.39 android=0
}

test_pi4_bookworm_and_trixie() {
    expect pi4 arch=aarch64 cpu_part=0xd08 glibc=2.36 android=0
    expect pi4 arch=aarch64 cpu_part=0xd08 glibc=2.41 android=0
}

test_cpu_part_case_insensitive() {
    expect pi4 arch=aarch64 cpu_part=0xD08 glibc=2.36
}

test_haswell_server_is_x86_64_v3() {
    expect x86_64-v3 arch=x86_64 "flags=$X86_FLAGS" glibc=2.31 android=0
}

# musl profiles need no host glibc (Alpine, busybox).
test_x86_without_glibc_still_matches() {
    expect x86_64-v3 arch=x86_64 "flags=$X86_FLAGS" glibc= android=0
}

test_old_glibc_gets_nothing() {
    expect "" arch=aarch64 cpu_part=0xd08 glibc=2.31 android=0
}

# Review Focus 4: getconf failed, so the glibc is unknown.
test_unknown_glibc_gets_nothing() {
    expect "" arch=aarch64 cpu_part=0xd42 glibc= android=0
    expect "" arch=aarch64 cpu_part=0xd42 android=0
}

test_unknown_cpu_part_gets_nothing() {
    expect "" arch=aarch64 cpu_part=0xd03 glibc=2.39 android=0
}

test_x86_without_avx2_gets_nothing() {
    expect "" arch=x86_64 "flags=fpu sse sse2 ssse3 fma bmi2" glibc=2.39 android=0
}

test_android_gets_nothing() {
    expect "" arch=aarch64 cpu_part=0xd05 glibc= android=1
    expect "" arch=aarch64 cpu_part=0xd08 glibc=2.36 android=1
}

test_wrong_arch_gets_nothing() {
    expect "" arch=armv7l cpu_part=0xd08 glibc=2.36 android=0
    expect "" arch=x86_64 cpu_part=0xd42 glibc=2.39 android=0
}

test_bad_argument_fails() {
    local got
    got="$(bash "$PICK" bogus 2>&1)" && fail "accepted 'bogus'"
    [[ $got == *Usage* ]] || fail "no usage: $got"
    return 0
}

for t in $(declare -F | awk '{print $3}' | grep '^test_'); do
    run_test "$t"
done

echo
echo "$PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
