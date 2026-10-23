# Shared by cross/*.sh: run a build inside the Jetson Yocto SDK container.
#
# Sourced on the host. Sources are cached in
# ${XDG_CACHE_HOME:-~/.cache}/zsh-portable/cross-src; QOS_IMAGE overrides the
# SDK image. Inside the container, /cross/sdk.sh provides the SDK environment
# and helpers for static libraries.

CROSS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CROSS_IMAGE=${QOS_IMAGE:-gitlab.quantum-systems.com:5050/ai/repo/devcontainer-yocto:latest}
CROSS_SRC="${XDG_CACHE_HOME:-$HOME/.cache}/zsh-portable/cross-src"

NCURSES_VERSION=6.5
LIBEVENT_VERSION=2.1.12-stable

# cross_require_aarch64 ARCH: the SDK only targets aarch64 (armv8a-oe4t-linux).
cross_require_aarch64() {
    [[ $1 == aarch64 ]] || { echo "${0##*/}: no cross toolchain for $1" >&2; exit 1; }
}

# cross_fetch FILE URL: download a source tarball once.
cross_fetch() {
    mkdir -p "$CROSS_SRC"
    [[ -s $CROSS_SRC/$1 ]] && return 0
    curl -fsSL -o "$CROSS_SRC/$1.tmp" "$2"
    mv "$CROSS_SRC/$1.tmp" "$CROSS_SRC/$1"
}

cross_fetch_ncurses() {
    cross_fetch "ncurses-$NCURSES_VERSION.tar.gz" \
        "https://ftp.gnu.org/gnu/ncurses/ncurses-$NCURSES_VERSION.tar.gz"
}

cross_fetch_libevent() {
    cross_fetch "libevent-$LIBEVENT_VERSION.tar.gz" \
        "https://github.com/libevent/libevent/releases/download/release-$LIBEVENT_VERSION/libevent-$LIBEVENT_VERSION.tar.gz"
}

# cross_run OUT [NAME=VALUE...]: run the bash script on stdin in the SDK
# container. It sees /src (sources), /cross (these scripts), OUT_NAME and the
# given variables, and must write /out/$OUT_NAME.
cross_run() {
    local out=$1
    shift
    local outdir env=() var
    mkdir -p "$(dirname "$out")"
    outdir="$(cd "$(dirname "$out")" && pwd)"
    for var in "$@" "OUT_NAME=$(basename "$out")" "NCURSES_VERSION=$NCURSES_VERSION" \
        "LIBEVENT_VERSION=$LIBEVENT_VERSION"; do
        env+=(-e "$var")
    done
    docker run --rm -i --user "$(id -u):$(id -g)" -e HOME=/tmp "${env[@]}" \
        -v "$CROSS_SRC:/src:ro" -v "$CROSS_DIR:/cross:ro" -v "$outdir:/out" \
        "$CROSS_IMAGE" bash -s
    chmod +x "$out"
}
