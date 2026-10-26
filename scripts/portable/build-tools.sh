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
TOOLS_FILE=${TOOLS_FILE:-$PORTABLE_DIR/tools.tsv}
LOCKS_DIR=${LOCKS_DIR:-$PORTABLE_DIR/locks}

# shellcheck source=lib.sh
source "$PORTABLE_DIR/lib.sh"

# Per tool, from tools.tsv (in file order: NAMES) and the lock (LOCK).
declare -a NAMES=()
declare -gA SOURCES=() REPOS=() FILES=() SPECS=() LOCK=()
ONLY=""

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

# selected NAME: whether NAME is in --only (all tools without it).
selected() {
    [[ -z $ONLY || ,$ONLY, == *",$1,"* ]]
}

# load_tools: the per-tool arrays for every tools.tsv row, and NAMES (file
# order) for the rows --only selects.
load_tools() {
    local name repo file spec source
    NAMES=()
    while read -r name repo file spec source; do
        [[ -z $name || $name == \#* ]] && continue
        REPOS[$name]=$repo FILES[$name]=$file SPECS[$name]=$spec SOURCES[$name]=$source
        selected "$name" && NAMES+=("$name")
    done <"$TOOLS_FILE"
}

# http_get URL: the body of URL; GitHub API calls carry the token if any.
http_get() {
    local -a auth=()
    if [[ $1 == https://api.github.com/* ]]; then
        load_github_token
        [[ -n ${EGET_GITHUB_TOKEN:-} ]] && auth=(-H "Authorization: Bearer $EGET_GITHUB_TOKEN")
    fi
    curl -fsSL --max-time 30 -A zsh-config-build-tools "${auth[@]}" "$1"
}

# json_get KEY...: the value at the KEY path of the JSON document on stdin.
json_get() {
    python3 -c '
import json, sys
v = json.load(sys.stdin)
for k in sys.argv[1:]:
    v = v[k]
print(v)
' "$@"
}

# latest_version SOURCE REPO: the newest upstream version for a tool.
latest_version() {
    local source=$1 repo=$2 module body version
    case $source in
        crate:*)
            IFS=: read -r _ module _ <<<"$source"
            body="$(http_get "https://crates.io/api/v1/crates/$module")" || return 1
            json_get crate max_stable_version <<<"$body"
            ;;
        go:*)
            module=${source#go:}
            module=${module%%//*}
            # The module proxy spells an uppercase letter as ! + lowercase.
            body="$(http_get "https://proxy.golang.org/$(sed 's/[A-Z]/!\L&/g' <<<"$module")/@latest")" || return 1
            version="$(json_get Version <<<"$body")" || return 1
            # Without v-prefixed semver tags the proxy only has pseudo-versions
            # of the default branch; the GitHub release tag is the release
            # (go install accepts a plain tag name).
            if [[ $version =~ -[0-9]{14}-[0-9a-f]{12}$ && $repo == */* ]] &&
                body="$(http_get "https://api.github.com/repos/$repo/releases/latest")"; then
                json_get tag_name <<<"$body" && return 0
            fi
            echo "$version"
            ;;
        cross:*)
            echo recipe
            ;;
        release)
            body="$(http_get "https://api.github.com/repos/$repo/releases/latest")" || return 1
            json_get tag_name <<<"$body"
            ;;
        *) return 1 ;;
    esac
}

# lock_file: the profile's lock.
lock_file() {
    echo "$LOCKS_DIR/$PROFILE_NAME.lock"
}

# read_lock: LOCK from the profile's lock, if there is one.
read_lock() {
    local name source version file
    file="$(lock_file)"
    LOCK=()
    [[ -r $file ]] || return 0
    while IFS=$'\t' read -r name source version; do
        [[ -z $name || $name == \#* ]] && continue
        LOCK[$name]=$version
    done <"$file"
}

# write_lock: the profile's lock from LOCK, sorted, for every tool in
# tools.tsv (entries of tools outside --only are kept as they were).
write_lock() {
    local file name
    file="$(lock_file)"
    mkdir -p "$LOCKS_DIR"
    {
        echo "# build-tools.sh lock for $PROFILE_NAME: name, source, version. Rewrite with --resolve."
        for name in "${!LOCK[@]}"; do
            [[ -n ${LOCK[$name]} && -n ${SOURCES[$name]:-} ]] || continue
            printf '%s\t%s\t%s\n' "$name" "${SOURCES[$name]}" "${LOCK[$name]}"
        done | sort
    } >"$file.tmp"
    mv "$file.tmp" "$file"
}

# resolve_versions MODE: fill LOCK for the selected tools. locked: the lock's
# versions, looking up only tools missing from it; resolve: look up every
# tool, keeping the old entry when a lookup fails.
resolve_versions() {
    local mode=$1 name version
    [[ ${#NAMES[@]} -gt 0 ]] || load_tools
    read_lock
    for name in "${NAMES[@]}"; do
        [[ $mode == locked && -n ${LOCK[$name]:-} ]] && continue
        if version="$(latest_version "${SOURCES[$name]}" "${REPOS[$name]}")" && [[ -n $version ]]; then
            LOCK[$name]=$version
        elif [[ -n ${LOCK[$name]:-} ]]; then
            log "$name: version lookup failed, keeping ${LOCK[$name]}"
        else
            log "$name: version lookup failed, no locked version"
        fi
    done
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
