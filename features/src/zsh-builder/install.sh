#!/usr/bin/env bash
#
# zsh-builder devcontainer feature: the toolchains build-tools.sh needs.
# Runs as root at image build. Options arrive as RUSTTARGETS and GOVERSION.
#
#   apt packages  compilers, pkg-config, python3, binutils (readelf), git
#   rustup        stable, minimal profile, plus RUSTTARGETS, in
#                 /usr/local/{cargo,rustup}
#   zig           newest stable release, /usr/local/zig
#   cargo-zigbuild
#   Go            GOVERSION or the newest, /usr/local/go
#   eget          /usr/local/bin

set -euo pipefail

RUSTTARGETS=${RUSTTARGETS:-x86_64-unknown-linux-musl,aarch64-unknown-linux-gnu}
GOVERSION=${GOVERSION:-latest}
export CARGO_HOME=/usr/local/cargo RUSTUP_HOME=/usr/local/rustup
export PATH="$CARGO_HOME/bin:/usr/local/go/bin:/usr/local/zig:$PATH"

echo "zsh-builder: packages"
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends \
    build-essential pkg-config git curl ca-certificates xz-utils python3 binutils file rsync
rm -rf /var/lib/apt/lists/*

case "$(dpkg --print-architecture)" in
    amd64) goarch=amd64 zigarch=x86_64 ;;
    arm64) goarch=arm64 zigarch=aarch64 ;;
    *) echo "zsh-builder: unsupported architecture" >&2; exit 1 ;;
esac

echo "zsh-builder: rustup"
curl --proto '=https' --tlsv1.2 -fsSL https://sh.rustup.rs |
    sh -s -- -y --no-modify-path --profile minimal --default-toolchain stable
IFS=, read -r -a targets <<<"$RUSTTARGETS"
rustup target add "${targets[@]}"

echo "zsh-builder: zig"
zig_url="$(curl -fsSL https://ziglang.org/download/index.json | python3 -c '
import json, sys
idx = json.load(sys.stdin)
key = lambda v: tuple(int(x) for x in v.split("."))
newest = max((v for v in idx if v != "master"), key=key)
print(idx[newest][sys.argv[1] + "-linux"]["tarball"])
' "$zigarch")"
mkdir -p /usr/local/zig
curl -fsSL "$zig_url" | tar -xJ -C /usr/local/zig --strip-components=1

echo "zsh-builder: cargo-zigbuild"
cargo install --locked cargo-zigbuild
rm -rf "$CARGO_HOME/registry" "$CARGO_HOME/git"

echo "zsh-builder: Go"
if [[ $GOVERSION == latest ]]; then
    GOVERSION="$(curl -fsSL 'https://go.dev/VERSION?m=text' | head -1)"
fi
GOVERSION=go${GOVERSION#go}
rm -rf /usr/local/go
curl -fsSL "https://go.dev/dl/$GOVERSION.linux-$goarch.tar.gz" | tar -xz -C /usr/local

echo "zsh-builder: eget"
tmp="$(mktemp -d)"
(cd "$tmp" && curl -fsSL https://zyedidia.github.io/eget.sh | bash)
install -m755 "$tmp/eget" /usr/local/bin/eget
rm -rf "$tmp"

# Builds run as the invoking user, with their own CARGO_HOME for the
# registry; the toolchains only need to be readable.
chmod -R a+rX /usr/local/cargo /usr/local/rustup /usr/local/go /usr/local/zig
echo "zsh-builder: done ($(rustc --version), $(zig version), $(go version | cut -d' ' -f3))"
