#!/usr/bin/env bash
#
# Build a self-contained zsh bundle for another machine or a devcontainer.
#
# Usage: build.sh --arch ARCH [--target zssh|dev] [--chezmoi DIR] [--force] [--refresh] [--strict] [--out DIR]
#
#   ARCH is the target's `uname -m` (aarch64, arm64, armv7l, x86_64).
#   --target picks the bundle (default zssh): zssh is for hosts reached over
#   ssh, dev for devcontainers. Each takes the manifest rows whose portable
#   column lists it.
#   Prints the path of the bundle on the last line of stdout (zssh:
#   zsh-portable-ARCH.tar.gz, dev: zsh-portable-dev-ARCH.tar.gz); progress
#   goes to stderr. A matching .version file holds the
#   bundle's content hash, which zssh compares with the remote copy.
#
#   The bundle holds a static zsh (romkatv/zsh-bin), the zsh dotfiles from
#   the chezmoi tree, antidote with every plugin already cloned, and the
#   tools of its apps/apps.tsv whose portable column lists the target built for ARCH. Nothing is fetched on
#   the target, so it works on hosts without internet.
#
#   The chezmoi tree (home/, apps/) is --chezmoi DIR, else $CHEZMOI_SRC, else
#   the top level of `chezmoi source-path`. portable/ belongs to this repo.
#   BUILDINFO in the bundle records the chezmoi and deploy commits (-dirty
#   when their inputs have uncommitted changes), the arch, the target and
#   the build time. It is not part of the version hash.
#
#   Secrets never go in: chezmoi runs with a throwaway config and
#   --exclude=encrypted, only allowlisted paths are exported, and the
#   finished tree is checked for age files, secret dirs, age identities and
#   every value from ~/.config/secrets/env before it is packed.
#
#   The bundle is rebuilt only when tracked or untracked files under home/ or
#   apps/ (chezmoi tree) or portable/ (this repo) change, or the yupps-zsh
#   plugin it ships does (this machine's ~/.config/zsh/plugins/yupps-zsh, or
#   $ZSSH_YUPPS_DIR). --force rebuilds anyway; --refresh also re-downloads zsh, tools and plugins.
#
#   A tool with no build for ARCH is skipped with a warning. --strict makes
#   that an error instead: after all tools are tried, the build fails with
#   one message listing every missing tool and writes no bundle, version or
#   stamp. Publishing uses it so an incomplete bundle never ships.
#
#   Caches live in ${XDG_CACHE_HOME:-~/.cache}/zsh-portable.

ZSH_BIN_TAG=v6.1.1
ZSH_BIN_VERSION=5.8

# Paths in the target home that go into the bundle.
EXPORT_PATHS=(
    .zshenv
    .config/zsh
    .config/atuin
    .config/bat
    .config/direnv
    .config/eza
    .config/fd
    .config/lsd
    .config/ripgrep
    .config/tmux
)

# chezmoi externals that go in too. Only archive-type externals: chezmoi
# archive can't include git-repo ones (antidote, cloned separately).
EXPORT_EXTERNALS=(
    .config/tmux/plugins
)

# Plugins that make no sense on someone else's machine.
DROP_PLUGINS_RE='plugins/ssh-agent([[:space:]]|$)'


log() { echo "build: $*" >&2; }
die() { echo "build: error: $*" >&2; exit 1; }

# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# Sourced (tests): resolve now. Run directly: main resolves after the flags,
# so --chezmoi beats a bad default and --help needs no tree.
if [[ ${BASH_SOURCE[0]} != "$0" ]]; then
    resolve_chezmoi_src || return 1
fi

# git_externals TOML PATH...: print "path<TAB>url<TAB>clone args" for every
# git-repo external in a rendered .chezmoiexternal.toml that lies in one of
# PATH. chezmoi archive can't include these, so build.sh clones them itself.
git_externals() {
    local toml=$1
    shift
    python3 - "$toml" "$@" <<'EOF'
import sys, tomllib
with open(sys.argv[1], "rb") as f:
    externals = tomllib.load(f)
roots = sys.argv[2:]
for path, ext in externals.items():
    if ext.get("type") != "git-repo":
        continue
    if not any(path == r or path.startswith(r + "/") for r in roots):
        continue
    args = " ".join(ext.get("clone", {}).get("args", []))
    print(f"{path}\t{ext['url']}\t{args}")
EOF
}

# yupps_dir: the yupps-zsh plugin to bundle: $ZSSH_YUPPS_DIR, else the
# checkout this machine runs (cloned by zshrc.d/71-custom-plugin.zsh).
yupps_dir() {
    echo "${ZSSH_YUPPS_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/zsh/plugins/yupps-zsh}"
}

# copy_yupps SRC DEST: copy the plugin without git metadata, tests and CI.
copy_yupps() {
    local src=$1 dest=$2
    mkdir -p "$dest"
    tar -C "$src" -cf - \
        --exclude=./.git --exclude=./tests --exclude=./.github --exclude=./.gitignore --exclude=./.opencode . |
        tar -C "$dest" -xf -
}

# filter_plugins: drop host-specific plugins from a .zsh_plugins.txt on stdin.
filter_plugins() {
    grep -Ev -- "$DROP_PLUGINS_RE" || true
}

# check_secrets DIR: fail if DIR holds anything that looks like a secret.
# SECRETS_FILE overrides the local secrets env file whose values are searched.
check_secrets() {
    local dir=$1 secrets=${SECRETS_FILE:-${XDG_CONFIG_HOME:-$HOME/.config}/secrets/env}
    local found=0 hits

    hits="$(cd "$dir" && find . \( -name '*.age' -o -name 'key.txt' \
        -o -name 'id_rsa*' -o -name 'id_ed25519*' -o -name 'id_ecdsa*' \
        -o -name '*.pem' -o -name '.git-credentials' \
        -o -path '*/secrets' -o -path '*/secrets/*' \) -print)"
    if [[ -n $hits ]]; then
        echo "secret-looking files in bundle:" >&2
        sed 's/^/  /' <<<"$hits" >&2
        found=1
    fi

    # Text files only: binaries like atuin embed the age identity prefix.
    if hits="$(grep -rlIF 'AGE-SECRET-KEY-' "$dir")"; then
        echo "age identity found in: $hits" >&2
        found=1
    fi

    if [[ -r $secrets ]]; then
        local line key value
        while IFS= read -r line || [[ -n $line ]]; do
            [[ $line =~ ^[[:space:]]*(export[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]] || continue
            key=${BASH_REMATCH[2]}
            value=${BASH_REMATCH[3]}
            value=${value#[\"\']}
            value=${value%[\"\']}
            (( ${#value} >= 8 )) || continue
            if hits="$(grep -rlF -- "$value" "$dir")"; then
                echo "value of secret $key found in: $hits" >&2
                found=1
            fi
        done <"$secrets"
    fi

    return "$found"
}

# input_stamp CHEZMOI DEPLOY ARCH TARGET [YUPPS_DIR]: hash of everything that
# affects the bundle, including the yupps-zsh plugin it ships.
input_stamp() {
    local chezmoi=$1 deploy=$2 arch=$3 target=$4 dev=${5:-} f
    local -a present=()
    {
        echo "$arch $target $ZSH_BIN_TAG"
        # Tracked files deleted in the working tree count by name only.
        while IFS= read -r -d '' f; do
            if [[ -f $chezmoi/$f ]]; then present+=("$f"); else echo "deleted $f"; fi
        done < <(cd "$chezmoi" && git ls-files -z -co --exclude-standard -- home apps | sort -zu)
        (( ${#present[@]} == 0 )) || (cd "$chezmoi" && sha256sum -- "${present[@]}")
        present=()
        while IFS= read -r -d '' f; do
            if [[ -f $deploy/$f ]]; then present+=("$f"); else echo "deleted $f"; fi
        done < <(cd "$deploy" && git ls-files -z -co --exclude-standard -- portable | sort -zu)
        (( ${#present[@]} == 0 )) || (cd "$deploy" && sha256sum -- "${present[@]}")
        if [[ -n $dev ]]; then
            echo "yupps $dev"
            (cd "$dev" && find . -path ./.git -prune -o -type f -print0 | sort -z | xargs -0 -r sha256sum)
        fi
    } | sha256sum | cut -d' ' -f1
}

# repo_rev DIR PATH...: short HEAD of DIR's repo, "-dirty" if PATHs have
# uncommitted changes, "unknown" outside a git repo.
repo_rev() {
    local dir=$1 sha
    shift
    sha="$(git -C "$dir" rev-parse --short HEAD 2>/dev/null)" || { echo unknown; return 0; }
    if [[ -n $(git -C "$dir" status --porcelain -- "$@" 2>/dev/null) ]]; then
        sha+=-dirty
    fi
    echo "$sha"
}

# build_info CHEZMOI DEPLOY ARCH TARGET: the BUILDINFO text.
build_info() {
    echo "chezmoi $(repo_rev "$1" home apps)"
    echo "deploy $(repo_rev "$2" portable)"
    echo "arch $3"
    echo "target $4"
    echo "built $(date -u +%Y-%m-%dT%H:%M:%SZ)"
}

# tree_hash DIR: content hash of a directory, used as the bundle version.
# Symlinks count by target path (some point at directories).
tree_hash() {
    (
        cd "$1" || exit
        find . -type f -print0 | sort -z | xargs -0 -r sha256sum
        find . -type l -print0 | sort -z | while IFS= read -r -d '' link; do
            printf '%s -> %s\n' "$link" "$(readlink "$link")"
        done
    ) | sha256sum | cut -c1-16
}

fetch_zsh() {
    local arch=$1 dest=$2
    local name="zsh-$ZSH_BIN_VERSION-linux-$arch"
    local tarball="$CACHE/downloads/$ZSH_BIN_TAG-$name.tar.gz"
    if [[ ! -s $tarball || -n $REFRESH ]]; then
        log "downloading $name"
        mkdir -p "$CACHE/downloads"
        curl -fsSL -o "$tarball.tmp" \
            "https://github.com/romkatv/zsh-bin/releases/download/$ZSH_BIN_TAG/$name.tar.gz"
        mv "$tarball.tmp" "$tarball"
    fi
    mkdir -p "$dest"
    tar -xzf "$tarball" -C "$dest"
    [[ -x $dest/bin/zsh ]] || tar -xzf "$tarball" -C "$dest" --strip-components=1
    [[ -x $dest/bin/zsh ]] || die "unexpected zsh-bin layout in $tarball"
    rm -rf "$dest/man"

    # zsh-bin ships terminfo as NN.zsh-bin dirs that its installer turns into
    # NN/ plus a letter dir (78/ and x/). Without that zsh finds no terminfo
    # on hosts lacking their own (Yocto), and zle can't move the cursor.
    local dir hex char
    for dir in "$dest"/share/terminfo/[0-9a-f][0-9a-f].zsh-bin; do
        [[ -d $dir ]] || continue
        hex=${dir##*/}
        hex=${hex%.zsh-bin}
        printf -v char "\\x$hex"
        mv "$dir" "$dest/share/terminfo/$hex"
        ln -s "$hex" "$dest/share/terminfo/$char"
    done
}

fetch_tools() {
    local arch=$1 dest=$2 target=$3
    local dir="$CACHE/tools/$arch" name release build
    MISSING_TOOLS=""
    mkdir -p "$dir" "$dest"
    apps_load || die "could not read the app manifest"

    for name in $(apps_names --portable "$target"); do
        build="$(app "$name" build)"
        release="$(app "$name" release)"
        if [[ -n $REFRESH || $(elf_arch "$dir/$name" 2>/dev/null) != "$arch" ]]; then
            rm -f "$dir/$name"
            local ok=""
            if [[ $build == cross:* ]]; then
                # Built from source by cross/NAME.sh ARCH OUT, which fails
                # for arches it can't build.
                log "building $name for $arch"
                if "$SCRIPT_DIR/cross/${build#cross:}.sh" "$arch" "$dir/$name" </dev/null >&2 \
                    && [[ $(elf_arch "$dir/$name") == "$arch" ]]; then
                    ok=1
                else
                    rm -f "$dir/$name"
                fi
            elif [[ $release != - ]] \
                && fetch_release "$name" "$release" "$(app "$name" file)" "$(app "$name" assets)" "$arch" "$dir/$name"; then
                ok=1
            fi
            if [[ -z $ok ]]; then
                log "warning: no $arch build of $name (${build/#-/$release}), skipping"
                MISSING_TOOLS+="${MISSING_TOOLS:+ }$name"
                continue
            fi
            log "fetched $name for $arch"
        fi
        cp "$dir/$name" "$dest/$name"
        chmod +x "$dest/$name"
    done
}

fetch_git_externals() {
    local dest=$1 tmp=$2
    local path url args key src
    chezmoi --source="$CHEZMOI_SRC" --config="$tmp/chezmoi.toml" \
        --persistent-state="$tmp/chezmoistate.db" --destination="$tmp/fake-home" \
        execute-template <"$CHEZMOI_SRC/home/.chezmoiexternal.toml.tmpl" >"$tmp/externals.toml" \
        2> >(grep -v 'config file template has changed' >&2) \
        || die "could not render .chezmoiexternal.toml.tmpl"
    while IFS=$'\t' read -r path url args; do
        # Keyed by url and clone args, so a branch change gets a fresh clone.
        key="$(printf '%s %s' "$url" "$args" | sha256sum | cut -c1-12)"
        src="$CACHE/git/${path//\//_}-$key"
        if [[ ! -d $src/.git ]]; then
            log "cloning $url ($path)"
            # shellcheck disable=SC2086 # args are separate git options
            git clone --quiet $args "$url" "$src" >&2 || die "could not clone $url"
        elif [[ -n $REFRESH ]]; then
            git -C "$src" pull --quiet --ff-only >&2 || die "could not update $src"
        fi
        mkdir -p "$dest/$path"
        tar -C "$src" --exclude=.git -cf - . | tar -C "$dest/$path" -xf -
    done < <(git_externals "$tmp/externals.toml" "${EXPORT_PATHS[@]}")
}

# fetch_plugins ANTIDOTE PLUGINS_TXT DEST: clone every plugin into an antidote
# home and copy it into DEST without .git, so the target never needs to clone.
fetch_plugins() {
    local antidote=$1 plugins=$2 dest=$3
    local home="$CACHE/antidote-home"
    command -v zsh >/dev/null || die "zsh is needed to resolve plugins"
    log "resolving plugins"
    ANTIDOTE_HOME="$home" zsh -fc '
        source "$1/antidote.zsh"
        zstyle ":antidote:bundle" use-friendly-names yes
        [[ -z $3 ]] || antidote update >/dev/null
        antidote bundle <"$2" >/dev/null
    ' _ "$antidote" "$plugins" "$REFRESH" >&2 \
        || die "antidote could not fetch plugins"
    mkdir -p "$dest"
    tar -C "$home" --exclude=.git -cf - . | tar -C "$dest" -xf -
}

export_dotfiles() {
    local dest=$1 tmp=$2
    local fake_home="$tmp/fake-home" targets=() path
    mkdir -p "$fake_home"
    # No age identity and hasSecrets=false: encrypted files can't be decrypted
    # even if the exclude below were dropped.
    printf '[data]\n    machine = "container"\n    hasSecrets = false\n' >"$tmp/chezmoi.toml"
    for path in "${EXPORT_PATHS[@]}"; do targets+=("$fake_home/$path"); done
    chezmoi --source="$CHEZMOI_SRC" --config="$tmp/chezmoi.toml" \
        --persistent-state="$tmp/chezmoistate.db" --destination="$fake_home" \
        archive --format=tar --exclude=encrypted,scripts,externals \
        --output="$tmp/dotfiles.tar" "${targets[@]}" \
        2> >(grep -v 'config file template has changed' >&2) \
        || die "chezmoi archive failed"
    mkdir -p "$dest"
    tar -xmf "$tmp/dotfiles.tar" -C "$dest"

    targets=()
    for path in "${EXPORT_EXTERNALS[@]}"; do targets+=("$fake_home/$path"); done
    chezmoi --source="$CHEZMOI_SRC" --config="$tmp/chezmoi.toml" \
        --persistent-state="$tmp/chezmoistate.db" --destination="$fake_home" \
        archive --format=tar --exclude=encrypted,scripts \
        --output="$tmp/externals.tar" "${targets[@]}" \
        2> >(grep -v 'config file template has changed' >&2) \
        || die "chezmoi archive of externals failed"
    tar -xmf "$tmp/externals.tar" -C "$dest"

    # yupps-zsh: the checkout this machine runs, minus .git, so the bundle
    # matches it and the offline target never clones.
    [[ -f $YUPPS_DIR/yupps.plugin.zsh ]] ||
        die "no yupps-zsh at $YUPPS_DIR (start zsh once to clone it, or set ZSSH_YUPPS_DIR)"
    log "bundling yupps-zsh from $YUPPS_DIR"
    copy_yupps "$YUPPS_DIR" "$dest/.config/zsh/plugins/yupps-zsh"
    # As zshrc.d/71-custom-plugin.zsh links it, so the theme loads at once.
    [[ -d $dest/.config/zsh/plugins/yupps-zsh/themes ]] &&
        ln -sfn plugins/yupps-zsh/themes "$dest/.config/zsh/themes"
    return 0
}

usage() {
    sed -n '3,42p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

main() {
    set -euo pipefail

    local arch="" target=zssh force="" out="" chezmoi="" strict=""
    REFRESH=""
    MISSING_TOOLS=""
    while (( $# )); do
        case $1 in
            --arch) arch=${2:-}; shift 2 ;;
            --target) target=${2:-}; shift 2 ;;
            --force) force=1; shift ;;
            --refresh) REFRESH=1; force=1; shift ;;
            --strict) strict=1; shift ;;
            --out) out=${2:-}; shift 2 ;;
            --chezmoi) chezmoi=${2:-}; shift 2 ;;
            -h | --help) usage; exit 0 ;;
            *) usage >&2; exit 2 ;;
        esac
    done
    [[ -n $arch ]] || { usage >&2; exit 2; }
    [[ $target == zssh || $target == dev ]] || { usage >&2; exit 2; }
    resolve_chezmoi_src "$chezmoi" || exit 2
    arch="$(normalize_arch "$arch")" || exit 1

    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    DEPLOY_DIR="$(dirname "$SCRIPT_DIR")"
    CACHE="${XDG_CACHE_HOME:-$HOME/.cache}/zsh-portable"
    out="${out:-$CACHE/dist}"
    mkdir -p "$out"

    local base="zsh-portable-$arch"
    [[ $target == zssh ]] || base="zsh-portable-$target-$arch"
    local bundle="$out/$base.tar.gz"
    local stamp_file="$out/$base.stamp"
    local version_file="$out/$base.version"
    local stamp
    YUPPS_DIR="$(yupps_dir)"
    stamp="$(input_stamp "$CHEZMOI_SRC" "$DEPLOY_DIR" "$arch" "$target" "$YUPPS_DIR")"
    if [[ -z $force && -s $bundle && -s $version_file \
        && $(cat "$stamp_file" 2>/dev/null) == "$stamp" ]]; then
        log "up to date: $bundle"
        echo "$bundle"
        return 0
    fi

    local tmp
    tmp="$(mktemp -d)"
    trap "rm -rf '$tmp'" EXIT
    local app="$tmp/app"

    log "building $target $arch bundle"
    export_dotfiles "$app/home" "$tmp"
    local plugins="$app/home/.config/zsh/.zsh_plugins.txt"
    filter_plugins <"$plugins" >"$plugins.tmp" && mv "$plugins.tmp" "$plugins"
    fetch_git_externals "$app/home" "$tmp"
    fetch_plugins "$app/home/.config/zsh/.antidote" "$plugins" "$app/antidote"
    fetch_zsh "$arch" "$app/zsh"
    fetch_tools "$arch" "$app/bin" "$target"
    [[ -z $strict || -z $MISSING_TOOLS ]] || die "missing tools: $MISSING_TOOLS"
    cp "$SCRIPT_DIR/remote/setup.sh" "$SCRIPT_DIR/remote/enter" "$app/"
    chmod +x "$app/setup.sh" "$app/enter"

    log "checking for secrets"
    check_secrets "$app" || die "refusing to build a bundle that contains secrets"

    local version
    version="$(tree_hash "$app")"
    echo "$version" >"$app/VERSION"
    build_info "$CHEZMOI_SRC" "$DEPLOY_DIR" "$arch" "$target" >"$app/BUILDINFO"
    # Owned by root in the archive, so root unpacking it on a host doesn't
    # leave files writable by whoever has this machine's uid there.
    tar --owner=0 --group=0 --numeric-owner -czf "$bundle.tmp" -C "$app" .
    mv "$bundle.tmp" "$bundle"
    echo "$version" >"$version_file"
    echo "$stamp" >"$stamp_file"
    log "built $bundle ($(du -h "$bundle" | cut -f1), version $version)"
    echo "$bundle"
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
    main "$@"
fi
