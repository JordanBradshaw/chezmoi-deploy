#!/usr/bin/env bash
#
# Build a static nethogs (musl, zig c++) for the portable bundles.
#
# Usage: nethogs.sh ARCH OUT
#
#   Linked with static ncurses and libpcap (deps.sh); libpcap's grammar
#   needs flex and bison. Without zig cc's default UBSan, which aborts on
#   harmless overflows. See lib.sh.

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

NETHOGS_VERSION=0.9.0
NETHOGS_SHA256=5961bef2155c05695d2fe7e79aa11194981b5afd1cad9bf1f259c7f30d5487c3

arch=${1:?usage: nethogs.sh ARCH OUT}
out=${2:?usage: nethogs.sh ARCH OUT}
static_target "$arch" >/dev/null

static_fetch "nethogs-$NETHOGS_VERSION.tar.gz" \
    "https://github.com/raboof/nethogs/archive/refs/tags/v$NETHOGS_VERSION.tar.gz" "$NETHOGS_SHA256"
static_fetch_ncurses
static_fetch_libpcap

echo "nethogs: building $NETHOGS_VERSION for $arch" >&2
STATIC_TOOLS="flex bison" static_run "$arch" "$out" "NETHOGS_VERSION=$NETHOGS_VERSION" <<'EOF'
source "$DEPS"
build_ncurses
build_libpcap
tar -xzf "$SRC/nethogs-$NETHOGS_VERSION.tar.gz"
cd "nethogs-$NETHOGS_VERSION/src"
quiet make -f MakeApp.mk -j"$JOBS" nethogs CC="$CC" CXX="$CXX" VERSION="$NETHOGS_VERSION" \
    CFLAGS="-O2 -fno-sanitize=undefined" \
    CXXFLAGS="-O2 -std=c++14 -Wno-missing-field-initializers -fno-sanitize=undefined" \
    CPPFLAGS="$CPPFLAGS" LDFLAGS="$LDFLAGS -static -s"
cp nethogs "$OUT_FILE"
EOF
