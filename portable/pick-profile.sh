#!/usr/bin/env bash
#
# Pick the build profile (portable/profiles/NAME.env) for a host from facts
# about it, as zssh's probe reports them.
#
# Usage: pick-profile.sh [KEY=VALUE...]
#
#   arch=ARCH       uname -m
#   cpu_part=PART   the first "CPU part" of /proc/cpuinfo (aarch64)
#   glibc=X.Y       getconf GNU_LIBC_VERSION's version, empty without glibc
#   flags=FLAGS     the first "flags" line of /proc/cpuinfo (x86_64)
#   android=0|1     whether the host is Android
#
#   Prints the first profile (by name) whose PROFILE_ARCH is ARCH, whose
#   DETECT_CPU_PART is PART or whose DETECT_X86_FLAGS are all in FLAGS, and
#   whose glibc floor (RUST_TARGET's .X.Y suffix) the host meets; musl
#   profiles need no glibc. Prints nothing when unsure: no profile without a
#   DETECT_* field, none for Android hosts, none when a glibc profile can't
#   see the host's glibc. Exit 2 on a bad argument.

set -euo pipefail

PROFILES_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/profiles"

usage() {
    sed -n '3,19p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

arch="" cpu_part="" glibc="" flags="" android=0
for kv in "$@"; do
    case $kv in
        arch=*) arch=${kv#*=} ;;
        cpu_part=*) cpu_part=${kv#*=} ;;
        glibc=*) glibc=${kv#*=} ;;
        flags=*) flags=${kv#*=} ;;
        android=*) android=${kv#*=} ;;
        -h | --help) usage; exit 0 ;;
        *) usage >&2; exit 2 ;;
    esac
done
[[ $android == 1 || -z $arch ]] && exit 0

# version_ge A B: version A is at least B.
version_ge() {
    [[ $(printf '%s\n%s\n' "$1" "$2" | sort -V | head -1) == "$2" ]]
}

# matches FILE: whether the profile in FILE fits the host.
matches() (
    # shellcheck source=/dev/null
    source "$1"
    [[ ${PROFILE_ARCH:-} == "$arch" ]] || return 1
    if [[ -n ${DETECT_CPU_PART:-} ]]; then
        [[ ${cpu_part,,} == "${DETECT_CPU_PART,,}" ]] || return 1
    elif [[ -n ${DETECT_X86_FLAGS:-} ]]; then
        local f
        for f in $DETECT_X86_FLAGS; do
            [[ " $flags " == *" $f "* ]] || return 1
        done
    else
        return 1
    fi
    if [[ ${RUST_TARGET:-} == *-gnu* ]]; then
        [[ -n $glibc ]] || return 1
        [[ ! $RUST_TARGET =~ gnu\.([0-9]+\.[0-9]+)$ ]] || version_ge "$glibc" "${BASH_REMATCH[1]}" || return 1
    elif [[ ${RUST_TARGET:-} != *-musl* ]]; then
        return 1
    fi
    return 0
)

for file in "$PROFILES_DIR"/*.env; do
    if matches "$file"; then
        name=${file##*/}
        echo "${name%.env}"
        exit 0
    fi
done
exit 0
