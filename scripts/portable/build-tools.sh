#!/usr/bin/env bash
#
# Build the zssh bundle's tools for a target profile.
#
# Usage: build-tools.sh --profile NAME [--resolve | --locked] [--only a,b]
#                       [--out DIR]
#
#   NAME is a file in profiles/ (arch, Rust target and CPU, Go settings).
#   Each tools.tsv row says how its tool is made (the source column):
#     crate:CRATE[:BIN][:ARGS]  cargo zigbuild from the crates.io source
#     go:MODULE[//SUBPKG]       go install for the profile's GOARCH
#     cross:NAME                cross/NAME.sh (needs the Yocto SDK)
#     release                   the upstream release, with eget
#
#   Versions come from locks/NAME.lock. --locked (the default) builds exactly
#   those; --resolve looks up the latest version of every tool and rewrites
#   the lock. A tool missing from the lock is looked up either way.
#
#   Builds are cached per tool, version and recipe, and checked (ELF arch;
#   static for musl profiles; glibc no newer than the target's). A tool that
#   fails keeps its newest cached build, else its release download; it never
#   fails the run. DIR gets bin/<name> for every tool and tools.lock.
#
#   Run inside the builder image (scripts/portable/builder.sh run ...), which
#   has the toolchains.

PORTABLE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROFILES_DIR="$PORTABLE_DIR/profiles"

log() { echo "build-tools: $*" >&2; }
die() { echo "build-tools: error: $*" >&2; exit 1; }

usage() {
    sed -n '3,25p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

# load_profile NAME: set PROFILE_NAME PROFILE_ARCH RUST_TARGET RUST_CPU
# GO_ENV NEEDS_SDK from profiles/NAME.env.
load_profile() {
    local file="$PROFILES_DIR/$1.env"
    if [[ ! $1 =~ ^[a-z0-9_-]+$ || ! -f $file ]]; then
        echo "build-tools: unknown profile $1" >&2
        return 1
    fi
    unset PROFILE_ARCH RUST_TARGET RUST_CPU GO_ENV NEEDS_SDK
    # shellcheck source=/dev/null
    source "$file"
    PROFILE_NAME=$1
}

# rust_target_dir: the Rust target without zigbuild's glibc suffix, as used
# in target/<dir>/release.
rust_target_dir() {
    echo "${RUST_TARGET%%.[0-9]*}"
}

main() {
    set -euo pipefail
    local profile="" mode=locked only="" out=""
    while (( $# )); do
        case $1 in
            --profile) profile=${2:-}; shift 2 ;;
            --resolve) mode=resolve; shift ;;
            --locked) mode=locked; shift ;;
            --only) only=${2:-}; shift 2 ;;
            --out) out=${2:-}; shift 2 ;;
            -h | --help) usage; exit 0 ;;
            *) usage >&2; exit 2 ;;
        esac
    done
    [[ -n $profile ]] || { usage >&2; exit 2; }
    load_profile "$profile" || exit 2
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
    main "$@"
fi
