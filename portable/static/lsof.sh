#!/usr/bin/env bash
#
# Build a static lsof (musl, zig cc) for the portable bundles.
#
# Usage: lsof.sh ARCH OUT
#
#   Without libtirpc (no RPC port names) and SELinux. See lib.sh.

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

LSOF_VERSION=4.99.7
LSOF_SHA256=4a10391aab0b8ce1f539e82a1966693b2a6cf225972a6504ebb7ec4fa71675de

arch=${1:?usage: lsof.sh ARCH OUT}
out=${2:?usage: lsof.sh ARCH OUT}
static_target "$arch" >/dev/null

static_fetch "lsof-$LSOF_VERSION.tar.gz" \
    "https://github.com/lsof-org/lsof/releases/download/$LSOF_VERSION/lsof-$LSOF_VERSION.tar.gz" "$LSOF_SHA256"

echo "lsof: building $LSOF_VERSION for $arch" >&2
static_run "$arch" "$out" "LSOF_VERSION=$LSOF_VERSION" <<'EOF'
tar -xzf "$SRC/lsof-$LSOF_VERSION.tar.gz"
cd "lsof-$LSOF_VERSION"
quiet ./configure --host="$TARGET" --disable-shared --disable-liblsof \
    --without-libtirpc --without-selinux CFLAGS=-O2 LDFLAGS="-static -s"
# Only the binary: the man page needs soelim.
quiet make -j"$JOBS" lsof
cp lsof "$OUT_FILE"
EOF
