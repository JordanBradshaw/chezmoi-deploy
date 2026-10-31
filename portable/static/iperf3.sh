#!/usr/bin/env bash
#
# Build a static iperf3 (musl, zig cc) for the portable bundles.
#
# Usage: iperf3.sh ARCH OUT
#
#   Without OpenSSL (no --rsa authentication). See lib.sh.

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

IPERF3_VERSION=3.22
IPERF3_SHA256=1c0d0fb02c52626111d6e132db80edfbf27bbaff8bd9245df2a371dcb0b35a92

arch=${1:?usage: iperf3.sh ARCH OUT}
out=${2:?usage: iperf3.sh ARCH OUT}
static_target "$arch" >/dev/null

static_fetch "iperf-$IPERF3_VERSION.tar.gz" \
    "https://github.com/esnet/iperf/releases/download/$IPERF3_VERSION/iperf-$IPERF3_VERSION.tar.gz" \
    "$IPERF3_SHA256"

echo "iperf3: building $IPERF3_VERSION for $arch" >&2
static_run "$arch" "$out" "IPERF3_VERSION=$IPERF3_VERSION" <<'EOF'
tar -xzf "$SRC/iperf-$IPERF3_VERSION.tar.gz"
cd "iperf-$IPERF3_VERSION"
quiet ./configure --host="$TARGET" --disable-shared --enable-static --without-openssl \
    --without-sctp LDFLAGS="-static -s"
quiet make -j"$JOBS"
cp src/iperf3 "$OUT_FILE"
EOF
