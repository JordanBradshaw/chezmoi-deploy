#!/usr/bin/env bash
#
# Run build-tools.sh and friends in the builder images.
#
# Usage: builder.sh image          build zsh-builder:local from
#                                  features/builder/x86_64.Dockerfile, then
#                                  zsh-builder-android:local on top of it
#        builder.sh run CMD [ARG]  run CMD in zsh-builder, from the repo (/src)
#        builder.sh build [PROFILE...] [-- ARG...]
#                                  build-tools.sh for each PROFILE (default:
#                                  every profiles/*.env) with compose.yaml;
#                                  ARGs go to build-tools.sh (--resolve,
#                                  --only a,b). Output: the cache's
#                                  tools-out/PROFILE/.
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
#
#   build writes the repo's .env for compose.yaml (ids, paths, images; no
#   secrets) and, for qos-orin, pulls the Yocto SDK image ($QOS_IMAGE) here
#   with this host's registry login. The services also get the Docker
#   socket ($DOCKER_SOCKET, default /var/run/docker.sock), which is root on
#   this host. A failed profile is reported at the end; the others still run.

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IMAGE=${BUILDER_IMAGE:-zsh-builder:local}
ANDROID_IMAGE=${ANDROID_BUILDER_IMAGE:-zsh-builder-android:local}
XDG_CACHE=${XDG_CACHE_HOME:-$HOME/.cache}
CACHE="$XDG_CACHE/zsh-portable"

usage() {
    sed -n '3,32p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

# setup_run: CHEZMOI_SRC, the GitHub token and the cache dirs.
setup_run() {
    # GitHub API limits: the host's token (env, secrets file or gh),
    # passed by name so it stays off the command line.
    # shellcheck source=lib.sh
    source "$REPO/portable/lib.sh"
    resolve_chezmoi_src || exit 1
    load_github_token
    mkdir -p "$CACHE/home" "$CACHE/xdg-cache"
}

# build PROFILE... [-- ARG...]: compose run per profile.
build() {
    local -a profiles=() args=() failed=()
    local p
    while (( $# )); do
        if [[ $1 == -- ]]; then shift; args=("$@"); break; fi
        profiles+=("$1")
        shift
    done
    if (( ${#profiles[@]} == 0 )); then
        for p in "$REPO"/portable/profiles/*.env; do p=${p##*/}; profiles+=("${p%.env}"); done
    fi
    for p in "${profiles[@]}"; do
        if [[ ! $p =~ ^[a-z0-9_-]+$ || ! -f $REPO/portable/profiles/$p.env ]]; then
            echo "builder: unknown profile $p" >&2
            exit 2
        fi
    done
    local sock=${DOCKER_SOCKET:-/var/run/docker.sock}
    [[ -e $sock ]] || { echo "builder: no Docker socket at $sock (set DOCKER_SOCKET)" >&2; exit 1; }
    setup_run
    local env_file=${BUILDER_ENV_FILE:-$REPO/.env}
    local qos_image=${QOS_IMAGE:-registry.example/sdk:latest}
    {
        echo "# Written by portable/builder.sh build; no secrets."
        echo "BUILDER_UID=$(id -u)"
        echo "BUILDER_GID=$(id -g)"
        echo "DOCKER_GID=$(stat -c %g "$sock")"
        echo "DOCKER_SOCKET=$sock"
        echo "REPO_DIR=$REPO"
        echo "CHEZMOI_SRC=$CHEZMOI_SRC"
        echo "ZSH_PORTABLE_CACHE=$CACHE"
        echo "BUILDER_IMAGE=$IMAGE"
        echo "ANDROID_BUILDER_IMAGE=$ANDROID_IMAGE"
        echo "QOS_IMAGE=$qos_image"
    } >"$env_file"
    if [[ " ${profiles[*]} " == *" qos-orin "* ]]; then
        docker pull "$qos_image" >&2 || echo "builder: could not pull $qos_image; using the local copy" >&2
    fi
    for p in "${profiles[@]}"; do
        echo "builder: building $p" >&2
        docker compose -f "$REPO/compose.yaml" --env-file "$env_file" run --rm "$p" "${args[@]}" ||
            failed+=("$p")
    done
    if (( ${#failed[@]} )); then
        echo "builder: failed: ${failed[*]}" >&2
        exit 1
    fi
}

case ${1:-} in
    image)
        docker build -f "$REPO/features/builder/x86_64.Dockerfile" -t "$IMAGE" "$REPO"
        docker build -f "$REPO/features/builder/android.Dockerfile" --build-arg BASE="$IMAGE" -t "$ANDROID_IMAGE" "$REPO"
        ;;
    run)
        shift
        (( $# )) || { usage >&2; exit 2; }
        setup_run
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
    build)
        shift
        build "$@"
        ;;
    *)
        usage >&2
        exit 2
        ;;
esac
