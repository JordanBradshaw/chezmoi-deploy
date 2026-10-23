#!/usr/bin/env bash
#
# Build a self-contained zsh bundle for another machine.
#
# Usage: build.sh --arch ARCH [--force] [--refresh] [--out DIR]
#
#   ARCH is the target's `uname -m` (aarch64, arm64, armv7l, x86_64).
#   Prints the path of the bundle (zsh-portable-ARCH.tar.gz) on the last line
#   of stdout; progress goes to stderr. A matching .version file holds the
#   bundle's content hash, which zssh compares with the remote copy.
#
#   The bundle holds a static zsh (romkatv/zsh-bin), the zsh dotfiles from
#   this repo, antidote with every plugin already cloned, and the tools in
#   tools.tsv built for ARCH. Nothing is fetched on the target, so it works
#   on hosts without internet.
#
#   Secrets never go in: chezmoi runs with a throwaway config and
#   --exclude=encrypted, only allowlisted paths are exported, and the
#   finished tree is checked for age files, secret dirs, age identities and
#   every value from ~/.config/secrets/env before it is packed.
#
#   The bundle is rebuilt only when tracked or untracked files under home/ or
#   scripts/portable/ change. --force rebuilds anyway; --refresh also
#   re-downloads zsh, tools and plugins.
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

# Release files that are never the binary we want.
ASSET_EXCLUDES=(^.deb ^.rpm ^.apk ^.msi ^.sha ^.sig ^.asc ^.sbom ^.pem)

log() { echo "build: $*" >&2; }
die() { echo "build: error: $*" >&2; exit 1; }

# normalize_arch UNAME_M: print the bundle arch name, or fail if unsupported.
normalize_arch() {
    case $1 in
        aarch64 | arm64) echo aarch64 ;;
        armv7l | armv7 | armhf | armv8l) echo armv7l ;;
        x86_64 | amd64) echo x86_64 ;;
        *)
            echo "unsupported arch: $1 (supported: aarch64, armv7l, x86_64)" >&2
            return 1
            ;;
    esac
}

# eget_system ARCH: eget --system value for a normalized arch.
eget_system() {
    case $1 in
        aarch64) echo linux/arm64 ;;
        armv7l) echo linux/arm ;;
        x86_64) echo linux/amd64 ;;
    esac
}

# asset_candidates ARCH SPEC: print one comma-separated filter list per line,
# in the order to try. An empty line means "no filters".
asset_candidates() {
    local arch=$1 spec=$2 alt
    if [[ $spec == - ]]; then
        echo
        return
    fi
    local IFS='|'
    for alt in $spec; do
        [[ $arch == armv7l ]] && echo "armv7,$alt"
        echo "$alt"
    done
}

# asset_args FILTERS: eget --asset arguments, one per line, for a
# comma-separated filter list plus excludes for packages and checksums.
asset_args() {
    local f fl=()
    IFS=, read -ra fl <<<"$1"
    for f in "${fl[@]}" "${ASSET_EXCLUDES[@]}"; do
        echo "--asset=$f"
    done
}

# elf_arch FILE: print the bundle arch an ELF binary was built for.
elf_arch() {
    local magic class machine
    magic="$(head -c4 "$1" 2>/dev/null | od -An -c | tr -d ' ')"
    [[ $magic == '177ELF' ]] || return 1
    class="$(od -An -tu1 -j4 -N1 "$1" | tr -d ' ')"
    machine="$(od -An -tu2 -j18 -N2 --endian=little "$1" | tr -d ' ')"
    case $class:$machine in
        2:62) echo x86_64 ;;
        2:183) echo aarch64 ;;
        1:40) echo armv7l ;;
        *) return 1 ;;
    esac
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

# input_stamp REPO ARCH: hash of everything that affects the bundle.
input_stamp() {
    local repo=$1 arch=$2
    {
        echo "$arch $ZSH_BIN_TAG"
        (cd "$repo" && git ls-files -z -co --exclude-standard -- home scripts/portable \
            | sort -z | xargs -0 -r sha256sum)
    } | sha256sum | cut -d' ' -f1
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

load_github_token() {
    [[ -n ${EGET_GITHUB_TOKEN:-} ]] && return 0
    local secrets="${XDG_CONFIG_HOME:-$HOME/.config}/secrets/env" line
    if [[ -r $secrets ]]; then
        while IFS= read -r line; do
            [[ $line == EGET_GITHUB_TOKEN=* ]] && EGET_GITHUB_TOKEN="${line#EGET_GITHUB_TOKEN=}"
        done <"$secrets"
    fi
    if [[ -z ${EGET_GITHUB_TOKEN:-} ]] && command -v gh >/dev/null 2>&1; then
        EGET_GITHUB_TOKEN="$(gh auth token 2>/dev/null || true)"
    fi
    [[ -n ${EGET_GITHUB_TOKEN:-} ]] && export EGET_GITHUB_TOKEN
    return 0
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
    local arch=$1 dest=$2
    local dir="$CACHE/tools/$arch" system name repo file spec filters
    mkdir -p "$dir" "$dest"
    system="$(eget_system "$arch")"
    # An empty config keeps ~/.eget.toml (target dir, upgrade_only) out of it.
    : >"$CACHE/eget.toml"
    load_github_token

    while read -r name repo file spec; do
        [[ -z $name || $name == \#* ]] && continue
        if [[ -n $REFRESH || $(elf_arch "$dir/$name" 2>/dev/null) != "$arch" ]]; then
            rm -f "$dir/$name"
            local ok=""
            if [[ $repo == cross:* ]]; then
                # Built from source by cross/NAME.sh ARCH OUT, which fails
                # for arches it can't build.
                log "building $name for $arch"
                if "$SCRIPT_DIR/cross/${repo#cross:}.sh" "$arch" "$dir/$name" </dev/null >&2 \
                    && [[ $(elf_arch "$dir/$name") == "$arch" ]]; then
                    ok=1
                else
                    rm -f "$dir/$name"
                fi
            fi
            while [[ $repo != cross:* ]] && IFS= read -r filters; do
                local args=(--system "$system" --file "$file" --to "$dir/$name" --quiet)
                mapfile -t -O "${#args[@]}" args < <(asset_args "$filters")
                if EGET_CONFIG="$CACHE/eget.toml" eget "${args[@]}" "$repo" </dev/null >/dev/null 2>&1; then
                    # Asset filters can leave a single asset for the wrong
                    # CPU, which eget takes without checking --system.
                    if [[ $(elf_arch "$dir/$name") == "$arch" ]]; then
                        ok=1
                        break
                    fi
                    rm -f "$dir/$name"
                fi
            done < <(asset_candidates "$arch" "$spec")
            if [[ -z $ok ]]; then
                log "warning: no $arch build of $name ($repo), skipping"
                continue
            fi
            log "fetched $name for $arch"
        fi
        cp "$dir/$name" "$dest/$name"
        chmod +x "$dest/$name"
    done <"$SCRIPT_DIR/tools.tsv"
}

fetch_antidote() {
    local dest=$1
    local src="$CACHE/antidote"
    if [[ ! -d $src/.git ]]; then
        log "cloning antidote"
        git clone --quiet --depth 1 https://github.com/mattmc3/antidote "$src"
    elif [[ -n $REFRESH ]]; then
        git -C "$src" pull --quiet --ff-only
    fi
    mkdir -p "$dest"
    tar -C "$src" --exclude=.git -cf - . | tar -C "$dest" -xf -
}

# fetch_plugins PLUGINS_TXT DEST: clone every plugin into an antidote home
# and copy it into DEST without .git, so the target never needs to clone.
fetch_plugins() {
    local plugins=$1 dest=$2
    local home="$CACHE/antidote-home"
    command -v zsh >/dev/null || die "zsh is needed to resolve plugins"
    log "resolving plugins"
    ANTIDOTE_HOME="$home" zsh -fc '
        source "$1/antidote.zsh"
        zstyle ":antidote:bundle" use-friendly-names yes
        [[ -z $3 ]] || antidote update >/dev/null
        antidote bundle <"$2" >/dev/null
    ' _ "$CACHE/antidote" "$plugins" "$REFRESH" >&2 \
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
    chezmoi --source="$REPO" --config="$tmp/chezmoi.toml" \
        --persistent-state="$tmp/chezmoistate.db" --destination="$fake_home" \
        archive --format=tar --exclude=encrypted,scripts,externals \
        --output="$tmp/dotfiles.tar" "${targets[@]}" \
        2> >(grep -v 'config file template has changed' >&2) \
        || die "chezmoi archive failed"
    mkdir -p "$dest"
    tar -xmf "$tmp/dotfiles.tar" -C "$dest"

    targets=()
    for path in "${EXPORT_EXTERNALS[@]}"; do targets+=("$fake_home/$path"); done
    chezmoi --source="$REPO" --config="$tmp/chezmoi.toml" \
        --persistent-state="$tmp/chezmoistate.db" --destination="$fake_home" \
        archive --format=tar --exclude=encrypted,scripts \
        --output="$tmp/externals.tar" "${targets[@]}" \
        2> >(grep -v 'config file template has changed' >&2) \
        || die "chezmoi archive of externals failed"
    tar -xmf "$tmp/externals.tar" -C "$dest"
}

usage() {
    sed -n '3,25p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

main() {
    set -euo pipefail

    local arch="" force="" out=""
    REFRESH=""
    while (( $# )); do
        case $1 in
            --arch) arch=${2:-}; shift 2 ;;
            --force) force=1; shift ;;
            --refresh) REFRESH=1; force=1; shift ;;
            --out) out=${2:-}; shift 2 ;;
            -h | --help) usage; exit 0 ;;
            *) usage >&2; exit 2 ;;
        esac
    done
    [[ -n $arch ]] || { usage >&2; exit 2; }
    arch="$(normalize_arch "$arch")" || exit 1

    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    REPO="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"
    CACHE="${XDG_CACHE_HOME:-$HOME/.cache}/zsh-portable"
    out="${out:-$CACHE/dist}"
    mkdir -p "$out"

    local bundle="$out/zsh-portable-$arch.tar.gz"
    local stamp_file="$out/zsh-portable-$arch.stamp"
    local version_file="$out/zsh-portable-$arch.version"
    local stamp
    stamp="$(input_stamp "$REPO" "$arch")"
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

    log "building $arch bundle"
    export_dotfiles "$app/home" "$tmp"
    local plugins="$app/home/.config/zsh/.zsh_plugins.txt"
    filter_plugins <"$plugins" >"$plugins.tmp" && mv "$plugins.tmp" "$plugins"
    fetch_antidote "$app/home/.config/zsh/.antidote"
    fetch_plugins "$plugins" "$app/antidote"
    fetch_zsh "$arch" "$app/zsh"
    fetch_tools "$arch" "$app/bin"
    cp "$SCRIPT_DIR/remote/setup.sh" "$SCRIPT_DIR/remote/enter" "$app/"
    chmod +x "$app/setup.sh" "$app/enter"

    log "checking for secrets"
    check_secrets "$app" || die "refusing to build a bundle that contains secrets"

    local version
    version="$(tree_hash "$app")"
    echo "$version" >"$app/VERSION"
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
