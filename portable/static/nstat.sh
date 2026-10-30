#!/usr/bin/env bash
#
# Build a static nstat (iproute2, musl, zig cc) for the portable bundles.
#
# Usage: nstat.sh ARCH OUT
#
#   Built like ss.sh (same tarball; tests keep the pins equal), but kept as
#   its own recipe so changing one never rebuilds the other. See lib.sh.

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

IPROUTE2_VERSION=7.3.0
IPROUTE2_SHA256=5c1789d290bba048a6135ed1ab81b0402dd0fb528d1f1421765c42b1fc3d6289

arch=${1:?usage: nstat.sh ARCH OUT}
out=${2:?usage: nstat.sh ARCH OUT}
static_target "$arch" >/dev/null

static_fetch "iproute2-$IPROUTE2_VERSION.tar.xz" \
    "https://mirrors.edge.kernel.org/pub/linux/utils/net/iproute2/iproute2-$IPROUTE2_VERSION.tar.xz" \
    "$IPROUTE2_SHA256"

echo "nstat: building iproute2 $IPROUTE2_VERSION for $arch" >&2
STATIC_TOOLS=bison static_run "$arch" "$out" "IPROUTE2_VERSION=$IPROUTE2_VERSION" <<'EOF'
tar -xJf "$SRC/iproute2-$IPROUTE2_VERSION.tar.xz"
cd "iproute2-$IPROUTE2_VERSION"
PKG_CONFIG=false quiet ./configure --libbpf_force off
quiet make -j"$JOBS" SUBDIRS="lib misc" LDFLAGS="-static -s"
cp misc/nstat "$OUT_FILE"
EOF
