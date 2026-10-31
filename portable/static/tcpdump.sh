#!/usr/bin/env bash
#
# Build a static tcpdump (musl, zig cc) for the portable bundles.
#
# Usage: tcpdump.sh ARCH OUT
#
#   Linked with the static libpcap from deps.sh (flex and bison for its
#   filter grammar); without libcrypto (no ESP decryption) and SMB printing.
#   See lib.sh.

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TCPDUMP_VERSION=4.99.7
TCPDUMP_SHA256=39675dfa06fb0e99be8da5d4a1784acbaab58ae0870231d956ff7870cb99eec1

arch=${1:?usage: tcpdump.sh ARCH OUT}
out=${2:?usage: tcpdump.sh ARCH OUT}
static_target "$arch" >/dev/null

static_fetch "tcpdump-$TCPDUMP_VERSION.tar.xz" \
    "https://www.tcpdump.org/release/tcpdump-$TCPDUMP_VERSION.tar.xz" "$TCPDUMP_SHA256"
static_fetch_libpcap

echo "tcpdump: building $TCPDUMP_VERSION for $arch" >&2
STATIC_TOOLS="flex bison" static_run "$arch" "$out" "TCPDUMP_VERSION=$TCPDUMP_VERSION" <<'EOF'
source "$DEPS"
build_libpcap
tar -xJf "$SRC/tcpdump-$TCPDUMP_VERSION.tar.xz"
cd "tcpdump-$TCPDUMP_VERSION"
PATH="$PREFIX/bin:$PATH" quiet ./configure --host="$TARGET" --without-crypto --disable-smb \
    --with-pcap=linux LDFLAGS="$LDFLAGS -static -s"
quiet make -j"$JOBS" tcpdump
cp tcpdump "$OUT_FILE"
EOF
