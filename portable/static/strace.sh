#!/usr/bin/env bash
#
# Build a static strace (musl, zig cc) for the portable bundles.
#
# Usage: strace.sh ARCH OUT
#
#   Without multiple personalities (mpers: tracing 32-bit programs from a
#   64-bit strace needs a multilib compiler) and stack traces (libunwind,
#   libdw). Built with gcc in Alpine for the target platform (qemu for arm;
#   see lib.sh): strace compiles against its own copy of the kernel headers,
#   which zig cc's newer bundled ones (Linux 7.2) override whatever the
#   include order, breaking the build.

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

STRACE_VERSION=7.3
STRACE_SHA256=529634c40910895a9a1f3c5c1e65da2ca9ed72fb158dfc4bcc89efdf05e39b72

arch=${1:?usage: strace.sh ARCH OUT}
out=${2:?usage: strace.sh ARCH OUT}
static_target "$arch" >/dev/null

static_fetch "strace-$STRACE_VERSION.tar.xz" \
    "https://github.com/strace/strace/releases/download/v$STRACE_VERSION/strace-$STRACE_VERSION.tar.xz" \
    "$STRACE_SHA256"

echo "strace: building $STRACE_VERSION for $arch" >&2
STATIC_ALPINE=1 STATIC_ALPINE_IMAGE=alpine:3.22 STATIC_APK="build-base linux-headers xz" \
    static_run "$arch" "$out" "STRACE_VERSION=$STRACE_VERSION" <<'EOF'
tar -xJf "$SRC/strace-$STRACE_VERSION.tar.xz"
cd "strace-$STRACE_VERSION"
quiet ./configure --enable-mpers=no --without-libunwind --without-libdw \
    --disable-gcc-Werror LDFLAGS="-static -s"
quiet make -j"$JOBS"
cp src/strace "$OUT_FILE"
EOF
