#!/usr/bin/env bash
#
# Run build-tools.sh and friends in the builder image.
#
# Usage: builder.sh image          build zsh-builder:local from
#                                  features/builder/x86_64.Dockerfile
#        builder.sh run CMD [ARG]  run CMD in it, from the repo (/src)
#
#   CMD runs as the invoking user. The repo is mounted at /src, the chezmoi
#   tree (CHEZMOI_SRC, else `chezmoi source-path`; read-write, since
#   build-tools.sh --resolve rewrites apps/locks) at /chezmoi, passed as
#   CHEZMOI_SRC=/chezmoi, and the
#   zsh-portable cache (${XDG_CACHE_HOME:-~/.cache}/zsh-portable) at the same
#   path as on the host, passed as ZSH_PORTABLE_CACHE so build-tools.sh finds
#   the same cache. HOME, XDG_CACHE_HOME, cargo's registry and zig's cache
#   are writable dirs inside it. The host's GitHub token (EGET_GITHUB_TOKEN,
#   ~/.config/secrets/env or gh) is passed in. BUILDER_IMAGE overrides the
#   image.

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IMAGE=${BUILDER_IMAGE:-zsh-builder:local}
XDG_CACHE=${XDG_CACHE_HOME:-$HOME/.cache}
CACHE="$XDG_CACHE/zsh-portable"

usage() {
    sed -n '3,18p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

case ${1:-} in
    image)
        docker build -f "$REPO/features/builder/x86_64.Dockerfile" -t "$IMAGE" "$REPO"
        ;;
    run)
        shift
        (( $# )) || { usage >&2; exit 2; }
        # GitHub API limits: the host's token (env, secrets file or gh),
        # passed by name so it stays off the command line.
        # shellcheck source=lib.sh
        source "$REPO/portable/lib.sh"
        resolve_chezmoi_src || exit 1
        load_github_token
        mkdir -p "$CACHE/home" "$CACHE/xdg-cache"
        tty=()
        [[ -t 0 && -t 1 ]] && tty=(-it)
        docker run --rm "${tty[@]}" \
            --user "$(id -u):$(id -g)" \
            -v "$REPO:/src" -w /src \
            -v "$CHEZMOI_SRC:/chezmoi" -e CHEZMOI_SRC=/chezmoi \
            -v "$CACHE:$CACHE" \
            -e ZSH_PORTABLE_CACHE="$CACHE" \
            -e XDG_CACHE_HOME="$CACHE/xdg-cache" \
            -e HOME="$CACHE/home" \
            -e CARGO_HOME="$CACHE/cargo-home" \
            -e ZIG_GLOBAL_CACHE_DIR="$CACHE/zig" \
            ${EGET_GITHUB_TOKEN:+-e EGET_GITHUB_TOKEN} \
            "$IMAGE" "$@"
        ;;
    *)
        usage >&2
        exit 2
        ;;
esac
