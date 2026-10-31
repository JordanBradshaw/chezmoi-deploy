# Shared by static/*.sh: build a fully static musl binary from source with
# zig cc.
#
# Sourced on the host. Sources are cached in
# ${ZSH_PORTABLE_CACHE:-${XDG_CACHE_HOME:-~/.cache}/zsh-portable}/static-src
# and checked against the sha256 pinned in each recipe. Builds run right here
# when zig and the recipe's STATIC_TOOLS are on PATH (inside the builder
# image, portable/builder.sh run), else in the builder image with docker
# (STATIC_IMAGE, default ghcr.io/jordanbradshaw/zsh-builder:latest), which
# apt-installs any missing STATIC_TOOLS first. STATIC_NATIVE=1 or 0 forces
# one or the other.
#
# A recipe that sets STATIC_ALPINE=1 (Rust with C libraries only Alpine
# ships static, like below's libelf; or code zig's headers break, like
# strace) always runs in STATIC_ALPINE_IMAGE (the recipe may set it) for
# the target's platform, emulated with qemu binfmt for other arches; it
# apk-installs bash, binutils and STATIC_APK first.

STATIC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATIC_SRC="${ZSH_PORTABLE_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/zsh-portable}/static-src"

# Libraries built by deps.sh.
NCURSES_VERSION=6.5
NCURSES_SHA256=136d91bc269a9a5785e5f9e980bc76ab57428f604ce3e5a5a90cebc767971cc6
LIBPCAP_VERSION=1.10.7
LIBPCAP_SHA256=68fa62cffb974f4275641ce14c2e2d75739251f30e00e6a0900903b247d76a03

# static_target ARCH: the zig target triple for a bundle arch.
static_target() {
    case $1 in
        x86_64) echo x86_64-linux-musl ;;
        aarch64) echo aarch64-linux-musl ;;
        armv7l) echo arm-linux-musleabihf ;;
        *) echo "${0##*/}: no static build for $1" >&2; return 1 ;;
    esac
}

STATIC_ALPINE_IMAGE=${STATIC_ALPINE_IMAGE:-rust:1.91-alpine3.22}

# static_platform ARCH: the docker platform for a bundle arch.
static_platform() {
    case $1 in
        x86_64) echo linux/amd64 ;;
        aarch64) echo linux/arm64 ;;
        armv7l) echo linux/arm/v7 ;;
        *) echo "${0##*/}: no static build for $1" >&2; return 1 ;;
    esac
}

# static_fetch FILE URL SHA256: download a source tarball once and check it.
static_fetch() {
    local file=$1 url=$2 sha=$3 path="$STATIC_SRC/$1"
    mkdir -p "$STATIC_SRC"
    if [[ -s $path ]] && sha256sum "$path" | grep -q "^$sha "; then
        return 0
    fi
    curl -fsSL -o "$path.tmp" "$url" || { rm -f "$path.tmp"; return 1; }
    if ! sha256sum "$path.tmp" | grep -q "^$sha "; then
        echo "${0##*/}: checksum mismatch for $file from $url" >&2
        rm -f "$path.tmp" "$path"
        return 1
    fi
    mv -f "$path.tmp" "$path"
}

static_fetch_ncurses() {
    static_fetch "ncurses-$NCURSES_VERSION.tar.gz" \
        "https://ftp.gnu.org/gnu/ncurses/ncurses-$NCURSES_VERSION.tar.gz" "$NCURSES_SHA256"
}

static_fetch_libpcap() {
    static_fetch "libpcap-$LIBPCAP_VERSION.tar.xz" \
        "https://www.tcpdump.org/release/libpcap-$LIBPCAP_VERSION.tar.xz" "$LIBPCAP_SHA256"
}

# The bash that runs a recipe (on stdin) in a temp dir, then checks that it
# left a static binary at OUT_FILE. Recipes get TARGET, CC, CXX, AR, RANLIB
# (zig; not for STATIC_ALPINE),
# SRC (the sources), PATCHES (static/patches), DEPS (deps.sh, to source),
# NCURSES_VERSION, LIBPCAP_VERSION, JOBS, OUT_FILE and their own variables, and `quiet CMD...`, which shows CMD's output only if it fails.
# shellcheck disable=SC2016 # expanded by the inner bash
STATIC_RUNNER='
set -euo pipefail
for tool in ${STATIC_TOOLS:-}; do
    command -v "$tool" >/dev/null && continue
    if [[ -n ${STATIC_APT:-} ]]; then
        { apt-get update -qq && apt-get install -y -qq --no-install-recommends "$tool"; } </dev/null >/dev/null 2>&1 ||
            { echo "static: could not install $tool" >&2; exit 1; }
    else
        echo "static: the build needs $tool" >&2
        exit 1
    fi
done
quiet() {
    local log status=0
    log=$(mktemp)
    "$@" >"$log" 2>&1 || status=$?
    (( status == 0 )) || tail -n 40 "$log" >&2
    rm -f "$log"
    return "$status"
}
recipe=$(cat)
work=$(mktemp -d)
trap '\''rm -rf "$work"'\'' EXIT
cd "$work"
rm -f "$OUT_FILE"
eval "$recipe"
if [[ ! -s $OUT_FILE ]]; then
    echo "static: the recipe wrote no $OUT_FILE" >&2
    exit 1
fi
if readelf -lW "$OUT_FILE" | grep -q INTERP; then
    echo "static: ${OUT_FILE##*/} is not statically linked" >&2
    rm -f "$OUT_FILE"
    exit 1
fi
chmod 755 "$OUT_FILE"
[[ -z ${OWNER:-} ]] || chown "$OWNER" "$OUT_FILE"
'

# static_native: whether to build here rather than in docker.
static_native() {
    [[ -z ${STATIC_ALPINE:-} ]] || return 1
    case ${STATIC_NATIVE:-} in
        1) return 0 ;;
        0) return 1 ;;
    esac
    local tool
    for tool in zig ${STATIC_TOOLS:-}; do
        command -v "$tool" >/dev/null || return 1
    done
}

# static_run ARCH OUT [NAME=VALUE...]: run the recipe on stdin for ARCH (see
# STATIC_RUNNER); it must leave a static binary at OUT.
static_run() {
    local arch=$1 out=$2
    shift 2
    local target outdir var
    target="$(static_target "$arch")" || return 1
    mkdir -p "$(dirname "$out")" "$STATIC_SRC"
    outdir="$(cd "$(dirname "$out")" && pwd)"
    local -a env=(
        "TARGET=$target" "NCURSES_VERSION=$NCURSES_VERSION" "LIBPCAP_VERSION=$LIBPCAP_VERSION"
        "JOBS=$(nproc 2>/dev/null || echo 4)" "STATIC_TOOLS=${STATIC_TOOLS:-}" "$@"
    )
    # Alpine builds use its native toolchain.
    [[ -n ${STATIC_ALPINE:-} ]] ||
        env+=("CC=zig cc -target $target" "CXX=zig c++ -target $target" "AR=zig ar" "RANLIB=zig ranlib")
    if static_native; then
        (
            for var in "${env[@]}" "SRC=$STATIC_SRC" "PATCHES=$STATIC_DIR/patches" "DEPS=$STATIC_DIR/deps.sh" "OUT_FILE=$outdir/${out##*/}"; do
                export "${var?}"
            done
            "$BASH" -c "$STATIC_RUNNER"
        )
    else
        local -a args=()
        for var in "${env[@]}" "SRC=/src" "PATCHES=/static/patches" "DEPS=/static/deps.sh" "OUT_FILE=/out/${out##*/}" \
            "OWNER=$(id -u):$(id -g)"; do
            args+=(-e "$var")
        done
        args+=(-v "$STATIC_SRC:/src:ro" -v "$STATIC_DIR:/static:ro" -v "$outdir:/out")
        if [[ -n ${STATIC_ALPINE:-} ]]; then
            local platform got
            platform="$(static_platform "$arch")" || return 1
            # The classic image store keeps one platform per tag, and run
            # --platform then uses whatever the tag holds: pull for this
            # platform, and refuse a tag still holding another (offline).
            docker pull -q --platform "$platform" "$STATIC_ALPINE_IMAGE" >/dev/null 2>&1 || true
            got="$(docker image inspect -f '{{.Os}}/{{.Architecture}}{{if .Variant}}/{{.Variant}}{{end}}' \
                "$STATIC_ALPINE_IMAGE" 2>/dev/null)"
            if [[ ${got%/v8} != "$platform" ]]; then
                echo "static: $STATIC_ALPINE_IMAGE is ${got:-missing}, not $platform" >&2
                return 1
            fi
            # shellcheck disable=SC2016 # expanded in the container
            docker run --rm -i --platform "$platform" "${args[@]}" -e STATIC_RUNNER="$STATIC_RUNNER" \
                "$STATIC_ALPINE_IMAGE" sh -c "apk add -q bash binutils ${STATIC_APK:-} >/dev/null && exec bash -c \"\$STATIC_RUNNER\""
        else
            docker run --rm -i "${args[@]}" -e STATIC_APT=1 \
                "${STATIC_IMAGE:-ghcr.io/jordanbradshaw/zsh-builder:latest}" bash -c "$STATIC_RUNNER"
        fi
    fi
}
