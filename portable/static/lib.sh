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

STATIC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATIC_SRC="${ZSH_PORTABLE_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/zsh-portable}/static-src"

# static_target ARCH: the zig target triple for a bundle arch.
static_target() {
    case $1 in
        x86_64) echo x86_64-linux-musl ;;
        aarch64) echo aarch64-linux-musl ;;
        armv7l) echo arm-linux-musleabihf ;;
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

# The bash that runs a recipe (on stdin) in a temp dir, then checks that it
# left a static binary at OUT_FILE. Recipes get TARGET, CC, AR, RANLIB, SRC
# (the sources), PATCHES (static/patches), JOBS, OUT_FILE and their own
# variables, and `quiet CMD...`, which shows CMD's output only if it fails.
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
        "TARGET=$target" "CC=zig cc -target $target" "AR=zig ar" "RANLIB=zig ranlib"
        "JOBS=$(nproc 2>/dev/null || echo 4)" "STATIC_TOOLS=${STATIC_TOOLS:-}" "$@"
    )
    if static_native; then
        (
            for var in "${env[@]}" "SRC=$STATIC_SRC" "PATCHES=$STATIC_DIR/patches" "OUT_FILE=$outdir/${out##*/}"; do
                export "${var?}"
            done
            "$BASH" -c "$STATIC_RUNNER"
        )
    else
        local -a args=()
        for var in "${env[@]}" "SRC=/src" "PATCHES=/static/patches" "OUT_FILE=/out/${out##*/}" \
            "STATIC_APT=1" "OWNER=$(id -u):$(id -g)"; do
            args+=(-e "$var")
        done
        docker run --rm -i "${args[@]}" \
            -v "$STATIC_SRC:/src:ro" -v "$STATIC_DIR:/static:ro" -v "$outdir:/out" \
            "${STATIC_IMAGE:-ghcr.io/jordanbradshaw/zsh-builder:latest}" bash -c "$STATIC_RUNNER"
    fi
}
