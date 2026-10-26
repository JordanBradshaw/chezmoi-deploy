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
CROSS_DIR=${CROSS_DIR:-$PORTABLE_DIR/cross}
CACHE_ROOT=${ZSH_PORTABLE_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/zsh-portable}

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
        if selected "$name"; then NAMES+=("$name"); fi
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

# build_crate NAME SOURCE VERSION OUT: cargo zigbuild the crates.io package
# for the profile's target and CPU. SOURCE is crate:CRATE[:BIN][:ARGS], ARGS
# comma-separated cargo arguments. Packages without a Cargo.lock build
# unlocked. Symbols are stripped: the binaries are copied to every host.
# RUSTUP_TOOLCHAIN overrides a crate's rust-toolchain.toml, whose extra
# components rustup can't install into the read-only builder toolchain.
build_crate() {
    local name=$1 source=$2 version=$3 out=$4 crate bin args work dir
    local -a extra=() locked=(--locked)
    IFS=: read -r _ crate bin args <<<"$source"
    bin=${bin:-$crate}
    [[ -n $args ]] && IFS=, read -r -a extra <<<"$args"
    mkdir -p "$CACHE_ROOT/tmp"
    work="$(mktemp -d "$CACHE_ROOT/tmp/crate.XXXXXX")"
    if ! http_get "https://crates.io/api/v1/crates/$crate/$version/download" >"$work/crate.tar.gz" \
        || ! tar -xzf "$work/crate.tar.gz" -C "$work"; then
        rm -rf "$work"
        return 1
    fi
    dir="$work/$crate-$version"
    [[ -f $dir/Cargo.lock ]] || locked=()
    local target_dir="$CACHE_ROOT/cargo-target/$PROFILE_NAME"
    if (cd "$dir" && env RUSTFLAGS="-C target-cpu=$RUST_CPU" \
        CARGO_PROFILE_RELEASE_LTO=fat CARGO_PROFILE_RELEASE_CODEGEN_UNITS=1 \
        CARGO_PROFILE_RELEASE_STRIP=symbols CARGO_TARGET_DIR="$target_dir" RUSTUP_TOOLCHAIN=stable \
        cargo zigbuild --release "${locked[@]}" --target "$RUST_TARGET" --bin "$bin" "${extra[@]}" >&2) \
        && install -D -m755 "$target_dir/$(rust_target_dir)/release/$bin" "$out"; then
        rm -rf "$work"
        return 0
    fi
    rm -rf "$work"
    return 1
}

# build_go NAME SOURCE VERSION OUT: go install the module (or its //SUBPKG)
# for the profile's GOARCH, stripped and without build paths.
build_go() {
    local name=$1 source=$2 version=$3 out=$4 pkg bin gopath goarch=""
    local -a goenv=()
    pkg=${source#go:}
    pkg=${pkg/\/\//\/}
    bin=${pkg##*/}
    # Major-version suffixes (/v2) aren't part of the binary name.
    [[ $bin =~ ^v[0-9]+$ ]] && { bin=${pkg%/*}; bin=${bin##*/}; }
    read -r -a goenv <<<"$GO_ENV"
    for v in "${goenv[@]}"; do [[ $v == GOARCH=* ]] && goarch=${v#GOARCH=}; done
    mkdir -p "$CACHE_ROOT/tmp"
    gopath="$(mktemp -d "$CACHE_ROOT/tmp/go.XXXXXX")"
    if env GOPATH="$gopath" GOMODCACHE="$CACHE_ROOT/gomod" GOCACHE="$CACHE_ROOT/gobuild" \
        GOFLAGS=-modcacherw GOOS=linux "${goenv[@]}" \
        go install -trimpath "-ldflags=-s -w" "$pkg@$version" >&2; then
        # Cross builds land in bin/linux_GOARCH.
        local f
        for f in "$gopath/bin/$bin" "$gopath/bin/linux_$goarch/$bin"; do
            if [[ -f $f ]]; then
                install -D -m755 "$f" "$out"
                rm -rf "$gopath"
                return 0
            fi
        done
    fi
    rm -rf "$gopath"
    return 1
}

# build_recipe NAME SOURCE REPO FILE SPEC VERSION OUT: make NAME's binary at
# OUT from its source at VERSION (see the header).
build_recipe() {
    local name=$1 source=$2 repo=$3 file=$4 spec=$5 version=$6 out=$7
    rm -f "$out"
    mkdir -p "$(dirname "$out")"
    case $source in
        crate:*) build_crate "$name" "$source" "$version" "$out" ;;
        go:*) build_go "$name" "$source" "$version" "$out" ;;
        cross:*)
            if [[ $NEEDS_SDK != 1 ]]; then
                log "$name: $source needs the Yocto SDK (profile $PROFILE_NAME has none)"
                return 1
            fi
            "$CROSS_DIR/${source#cross:}.sh" "$PROFILE_ARCH" "$out" </dev/null >&2
            ;;
        release) fetch_release "$name" "$repo" "$file" "$spec" "$PROFILE_ARCH" "$out" "$version" ;;
        *) log "$name: unknown source $source"; return 1 ;;
    esac
}

# verify_binary FILE: FILE is an ELF binary for the profile's arch; static for
# musl targets; for glibc targets with a version suffix (….2.39) it needs no
# newer GLIBC_ symbol version.
verify_binary() {
    local file=$1 arch need max
    arch="$(elf_arch "$file" 2>/dev/null)" || { log "${file##*/}: not an ELF binary"; return 1; }
    [[ $arch == "$PROFILE_ARCH" ]] || { log "${file##*/}: built for $arch, not $PROFILE_ARCH"; return 1; }
    if [[ $RUST_TARGET == *musl* ]] && readelf -lW "$file" 2>/dev/null | grep -q INTERP; then
        log "${file##*/}: not static (has an ELF interpreter)"
        return 1
    fi
    if [[ $RUST_TARGET =~ gnu\.([0-9]+\.[0-9]+)$ ]]; then
        max=${BASH_REMATCH[1]}
        need="$(readelf -VW "$file" 2>/dev/null | grep -o 'GLIBC_[0-9][0-9.]*' | sed 's/GLIBC_//' | sort -uV | tail -1)"
        if [[ -n $need && $(printf '%s\n%s\n' "$need" "$max" | sort -V | tail -1) != "$max" ]]; then
            log "${file##*/}: needs GLIBC_$need, target has $max"
            return 1
        fi
    fi
    return 0
}

# Build settings applied by build_crate/build_go; part of every cache key.
BUILD_SETTINGS="cargo: lto=fat codegen-units=1 strip=symbols; go: -trimpath -ldflags=-s -w"

# recipe_hash NAME: short hash of NAME's tools.tsv row, the profile and
# BUILD_SETTINGS, so a changed recipe never reuses an old build.
recipe_hash() {
    {
        printf '%s\n' "$1" "${REPOS[$1]}" "${FILES[$1]}" "${SPECS[$1]}" "${SOURCES[$1]}" "$BUILD_SETTINGS"
        cat "$PROFILES_DIR/$PROFILE_NAME.env"
    } | sha256sum | cut -c1-12
}

# cache_path NAME VERSION: where NAME's verified build at VERSION is kept.
cache_path() {
    echo "$CACHE_ROOT/tools/$PROFILE_NAME/$1/$2-$(recipe_hash "$1")/$1"
}

# obtain_tool NAME DEST: put NAME's binary at DEST and set HOW and GOT_VERSION:
# the cached or freshly built (and verified) locked version, else the newest
# cached build of any version, else the upstream release. Builds happen in a
# temp dir and only move into the cache once verified.
obtain_tool() {
    local name=$1 dest=$2 version=${LOCK[$1]:-} cached tmp
    HOW="" GOT_VERSION=""
    if [[ -n $version ]]; then
        cached="$(cache_path "$name" "$version")"
        if [[ -f $cached ]]; then
            HOW=cached
        else
            mkdir -p "$CACHE_ROOT/tmp"
            tmp="$(mktemp -d "$CACHE_ROOT/tmp/build.XXXXXX")"
            log "building $name $version for $PROFILE_NAME"
            # Release binaries are used as published (fetch_release checked
            # the arch); the static/glibc checks are for binaries built here.
            if build_recipe "$name" "${SOURCES[$name]}" "${REPOS[$name]}" "${FILES[$name]}" \
                "${SPECS[$name]}" "$version" "$tmp/$name" &&
                { [[ ${SOURCES[$name]} == release ]] || verify_binary "$tmp/$name"; }; then
                mkdir -p "$(dirname "$cached")"
                mv -f "$tmp/$name" "$cached"
                HOW=built
            else
                log "$name: build of $version failed"
            fi
            rm -rf "$tmp"
        fi
        if [[ -n $HOW ]]; then
            install -m755 "$cached" "$dest"
            GOT_VERSION=$version
            return 0
        fi
    fi
    # Newest cached build of any version, for any recipe.
    cached="$(ls -t "$CACHE_ROOT/tools/$PROFILE_NAME/$name"/*/"$name" 2>/dev/null | head -1 || true)"
    if [[ -n $cached ]]; then
        install -m755 "$cached" "$dest"
        HOW=fallback-cache
        GOT_VERSION="$(basename "$(dirname "$cached")")"
        GOT_VERSION=${GOT_VERSION%-*}
        return 0
    fi
    # The latest upstream release; checked for the arch only, like the
    # eget-only bundles.
    if fetch_release "$name" "${REPOS[$name]}" "${FILES[$name]}" "${SPECS[$name]}" "$PROFILE_ARCH" "$dest"; then
        HOW=fallback-release
        GOT_VERSION=release
        return 0
    fi
    return 1
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
    ONLY=$only
    out=${out:-$CACHE_ROOT/tools-out/$PROFILE_NAME}

    load_tools
    read_lock
    local -A old_lock=()
    local name
    for name in "${!LOCK[@]}"; do old_lock[$name]=${LOCK[$name]}; done
    resolve_versions "$mode"

    rm -rf "$out/bin"
    mkdir -p "$out/bin"
    local -a lines=() skipped=()
    for name in "${NAMES[@]}"; do
        if obtain_tool "$name" "$out/bin/$name"; then
            lines+=("$(printf '%s\t%s\t%s\t%s\t%s' "$name" "${SOURCES[$name]}" "$GOT_VERSION" \
                "$(sha256sum "$out/bin/$name" | cut -d' ' -f1)" "$HOW")")
        else
            log "$name: no build for $PROFILE_NAME, skipping"
            skipped+=("$name")
        fi
        # A new version that didn't build isn't locked; the old one stays.
        if [[ $mode == resolve && $HOW != built && $HOW != cached ]]; then
            if [[ -n ${old_lock[$name]:-} ]]; then LOCK[$name]=${old_lock[$name]}; else unset "LOCK[$name]"; fi
        fi
    done

    {
        echo "# tools.lock ($PROFILE_NAME): name, source, version, sha256, how (built|cached|fallback-cache|fallback-release)"
        if (( ${#lines[@]} )); then printf '%s\n' "${lines[@]}" | sort; fi
    } >"$out/tools.lock"
    [[ $mode == resolve ]] && write_lock
    log "built ${#lines[@]} tools into $out${skipped[*]:+ (skipped: ${skipped[*]})}"
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
    main "$@"
fi
