#!/usr/bin/env bash
#
# Build a static iftop (musl, zig cc) for the portable bundles.
#
# Usage: iftop.sh ARCH OUT
#
#   Linked with static ncurses and libpcap (deps.sh); libpcap's grammar
#   needs flex and bison. iftop 1.0pre4 predates -fno-common being the
#   default, hence -fcommon. See lib.sh.

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

IFTOP_VERSION=1.0pre4
IFTOP_SHA256=f733eeea371a7577f8fe353d86dd88d16f5b2a2e702bd96f5ffb2c197d9b4f97

arch=${1:?usage: iftop.sh ARCH OUT}
out=${2:?usage: iftop.sh ARCH OUT}
static_target "$arch" >/dev/null

static_fetch "iftop-$IFTOP_VERSION.tar.gz" \
    "https://pdw.ex-parrot.com/iftop/download/iftop-$IFTOP_VERSION.tar.gz" "$IFTOP_SHA256"
static_fetch_ncurses
static_fetch_libpcap

echo "iftop: building $IFTOP_VERSION for $arch" >&2
STATIC_TOOLS="flex bison" static_run "$arch" "$out" "IFTOP_VERSION=$IFTOP_VERSION" <<'EOF'
source "$DEPS"
build_ncurses
build_libpcap
tar -xzf "$SRC/iftop-$IFTOP_VERSION.tar.gz"
cd "iftop-$IFTOP_VERSION"
# config.sub from 2014 knows no aarch64-linux-musl; the build is a cross
# build either way.
quiet ./configure --host=x86_64-pc-linux-gnu --build=x86_64-pc-linux-gnu \
    --with-libpcap="$PREFIX" --with-resolver=netdb \
    CFLAGS="-O2 -fcommon" LDFLAGS="$LDFLAGS -static -s"
quiet make -j"$JOBS"
cp iftop "$OUT_FILE"
EOF
