#!/bin/sh
#
# zsh-config devcontainer feature: install the zsh-portable dev bundle into the
# remote user's real home, laid out like a chezmoi install. Runs as root at
# image build; options arrive as VERSION, BUNDLEURL and DEFAULTSHELL.

set -eu

die() {
    echo "zsh-config: $*" >&2
    exit 1
}

[ "$(uname -m)" = x86_64 ] || die "only x86_64 bundles are published"

VERSION=${VERSION:-latest}
BUNDLEURL=${BUNDLEURL:-}
DEFAULTSHELL=${DEFAULTSHELL:-true}
ASSET=zsh-portable-dev-x86_64.tar.gz

user=${_REMOTE_USER:-root}
home=${_REMOTE_USER_HOME:-}
if [ "$user" = root ]; then
    home=/root
elif [ -z "$home" ]; then
    home=$(getent passwd "$user" | cut -d: -f6)
fi
[ -n "$home" ] || die "no home directory for $user"
id "$user" >/dev/null 2>&1 || die "no such user: $user"
group=$(id -gn "$user")

need=""
command -v curl >/dev/null 2>&1 || need="$need curl"
command -v tar >/dev/null 2>&1 || need="$need tar"
command -v gzip >/dev/null 2>&1 || need="$need gzip"
if [ -n "$need" ]; then
    if command -v apt-get >/dev/null 2>&1; then
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -y
        # shellcheck disable=SC2086
        apt-get install -y --no-install-recommends ca-certificates $need
        rm -rf /var/lib/apt/lists/*
    elif command -v apk >/dev/null 2>&1; then
        # shellcheck disable=SC2086
        apk add --no-cache ca-certificates $need
    elif command -v dnf >/dev/null 2>&1; then
        # shellcheck disable=SC2086
        dnf install -y ca-certificates $need
        dnf clean all
    else
        die "cannot install:$need"
    fi
fi

if [ -n "$BUNDLEURL" ]; then
    url=$BUNDLEURL
else
    tag=$VERSION
    [ "$tag" != latest ] || tag=bundles
    url=https://github.com/JordanBradshaw/chezmoi-deploy/releases/download/$tag/$ASSET
fi
base=${url%/*}

stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT
echo "zsh-config: downloading $url"
curl -fsSL -o "$stage/$ASSET" "$url" || die "download failed: $url"
curl -fsSL -o "$stage/SHA256SUMS" "$base/SHA256SUMS" || die "download failed: $base/SHA256SUMS"
grep "  $ASSET\$" "$stage/SHA256SUMS" >"$stage/sum" || die "$ASSET missing from SHA256SUMS"
(cd "$stage" && sha256sum -c sum >/dev/null) || die "checksum mismatch for $ASSET"

mkdir "$stage/b"
tar -xzf "$stage/$ASSET" -C "$stage/b"
rm -f "$stage/$ASSET"
b=$stage/b
app=$home/.local/share/zsh-config
sh "$b/setup.sh" "$app"

# Everything from here on touches the user's home.
mkdir -p "$home/.local/bin" "$app" "$home/.config" "$home/.cache"

for tool in "$b"/bin/*; do
    [ -f "$tool" ] || continue
    rm -f "$home/.local/bin/${tool##*/}"
    mv "$tool" "$home/.local/bin/"
done

rm -rf "$app/zsh"
mv "$b/zsh" "$app/zsh"
ln -sfn "$app/zsh/bin/zsh" "$home/.local/bin/zsh"
ln -sfn "$app/zsh/bin/zsh" /usr/local/bin/zsh
cp "$b/VERSION" "$b/BUILDINFO" "$app/"

for dir in "$b"/home/.config/* "$b"/home/.config/.[!.]*; do
    [ -e "$dir" ] || continue
    rm -rf "$home/.config/${dir##*/}"
    mv "$dir" "$home/.config/"
done
if [ -e "$home/.zshenv" ] && ! grep -q '>>> zsh-config >>>' "$home/.zshenv" \
    && [ ! -e "$home/.zshenv.pre-zsh-config" ]; then
    mv "$home/.zshenv" "$home/.zshenv.pre-zsh-config"
fi
rm -f "$home/.zshenv"
mv "$b/home/.zshenv" "$home/.zshenv"

rm -rf "$home/.cache/antidote"
mv "$b/antidote" "$home/.cache/antidote"

cat >"$home/.config/zsh/zshenv.d/05-zsh-config.zsh" <<'EOF'
# Written by the zsh-config devcontainer feature: plugins and the theme come
# pre-cloned with the bundle, so nothing is cloned or pulled at shell start.
export ZSH_PORTABLE=${ZSH_PORTABLE:-$HOME/.local/share/zsh-config}
EOF

# State lives on the feature's volume so history survives rebuilds; a new
# volume is seeded from the image, ownership included.
state=/var/lib/zsh-config
mkdir -p "$state/zsh" "$state/atuin" "$state/zoxide" "$home/.local/state" "$home/.local/share"
for pair in "state/zsh:zsh" "share/atuin:atuin" "share/zoxide:zoxide"; do
    link=$home/.local/${pair%%:*}
    target=$state/${pair#*:}
    if [ -d "$link" ] && [ ! -L "$link" ]; then
        cp -a "$link"/. "$target"/ 2>/dev/null || true
        rm -rf "$link"
    fi
    ln -sfn "$target" "$link"
done
chown -R "$user:$group" "$state"

chown -R -h "$user:$group" "$home/.local" "$home/.config" "$home/.cache" "$home/.zshenv"
[ ! -e "$home/.zshenv.pre-zsh-config" ] || chown -h "$user:$group" "$home/.zshenv.pre-zsh-config"

grep -qx /usr/local/bin/zsh /etc/shells 2>/dev/null || echo /usr/local/bin/zsh >>/etc/shells
if [ "$DEFAULTSHELL" = true ]; then
    if command -v chsh >/dev/null 2>&1; then
        chsh -s /usr/local/bin/zsh "$user"
    elif command -v usermod >/dev/null 2>&1; then
        usermod -s /usr/local/bin/zsh "$user"
    else
        sed -i "s|^\($user:.*:\)[^:]*\$|\1/usr/local/bin/zsh|" /etc/passwd
    fi
fi

echo "zsh-config: installed $(cat "$app/VERSION") for $user"
