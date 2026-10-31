#!/usr/bin/env bash
#
# Build a static ethtool (musl, zig cc) for the portable bundles.
#
# Usage: ethtool.sh ARCH OUT
#
#   Without netlink (no libmnl): every query goes through the ioctl
#   interface, which covers -i, -S, -k, -g, -l and -a; netlink-only
#   extras (--json, cable tests, PSE) are missing. See lib.sh.

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ETHTOOL_VERSION=7.2
ETHTOOL_SHA256=44256ddf4631ed08d816b7b8725f4b2e0f05e96b8c7ca64ee5c81449da2b6507

arch=${1:?usage: ethtool.sh ARCH OUT}
out=${2:?usage: ethtool.sh ARCH OUT}
static_target "$arch" >/dev/null

static_fetch "ethtool-$ETHTOOL_VERSION.tar.xz" \
    "https://mirrors.edge.kernel.org/pub/software/network/ethtool/ethtool-$ETHTOOL_VERSION.tar.xz" \
    "$ETHTOOL_SHA256"

echo "ethtool: building $ETHTOOL_VERSION for $arch" >&2
static_run "$arch" "$out" "ETHTOOL_VERSION=$ETHTOOL_VERSION" <<'EOF'
tar -xJf "$SRC/ethtool-$ETHTOOL_VERSION.tar.xz"
cd "ethtool-$ETHTOOL_VERSION"
quiet ./configure --host="$TARGET" --disable-netlink LDFLAGS="-static -s"
quiet make -j"$JOBS" ethtool
cp ethtool "$OUT_FILE"
EOF
