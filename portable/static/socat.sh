#!/usr/bin/env bash
#
# Build a static socat (musl, zig cc) for the portable bundles.
#
# Usage: socat.sh ARCH OUT
#
#   Without OpenSSL (no OPENSSL: addresses), readline and libwrap. zig cc
#   adds UBSan unless told not to, and socat trips it at startup. See
#   lib.sh.

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SOCAT_VERSION=1.8.1.3
SOCAT_SHA256=06602ffd591e98c75b3dc1d66f0f19136cc666b0b2d95caad987d6ab2cb28097

arch=${1:?usage: socat.sh ARCH OUT}
out=${2:?usage: socat.sh ARCH OUT}
static_target "$arch" >/dev/null

static_fetch "socat-$SOCAT_VERSION.tar.gz" \
    "http://www.dest-unreach.org/socat/download/socat-$SOCAT_VERSION.tar.gz" "$SOCAT_SHA256"

echo "socat: building $SOCAT_VERSION for $arch" >&2
static_run "$arch" "$out" "SOCAT_VERSION=$SOCAT_VERSION" <<'EOF'
tar -xzf "$SRC/socat-$SOCAT_VERSION.tar.gz"
cd "socat-$SOCAT_VERSION"
quiet ./configure --host="$TARGET" --disable-openssl --disable-readline --disable-libwrap \
    CFLAGS="-O2 -fno-sanitize=undefined -Wno-date-time" LDFLAGS="-static -s"
quiet make -j"$JOBS" socat
cp socat "$OUT_FILE"
EOF
