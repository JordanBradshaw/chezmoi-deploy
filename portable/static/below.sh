#!/usr/bin/env bash
#
# Build a static below (Meta's resource monitor) for the portable bundles.
#
# Usage: below.sh ARCH OUT
#
#   Rust with libbpf, linked against Alpine's static libelf, zlib and zstd,
#   so it runs in rust:alpine for the target platform (see lib.sh;
#   aarch64 through qemu binfmt, slow). Alpine's libelf.a needs zstd, which
#   libbpf-sys doesn't link, and gcc's aarch64 libbpf calls libgcc's
#   outline atomics, which rustc's -nodefaultlibs drops: the linker wrapper
#   adds both. Newer clang rejects
#   a pointer cast in below's BPF code: the clang wrapper relaxes it.
#   rustfmt formats the generated BPF skeleton. No armv7l (no rust:alpine
#   image).
#
#   patches/below/*.patch apply to the fetched fb_procfs (below's /proc
#   reader): kernels without CONFIG_TASK_IO_ACCOUNTING (Jetson L4T) have no
#   /proc/PID/io, and unpatched below skips every process and records
#   nothing.

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BELOW_VERSION=0.9.0
BELOW_SHA256=38e9f87936bc2fa6beb9519855fe343fa6e002b457b5e8b6e6e82ca68bc0ea61

arch=${1:?usage: below.sh ARCH OUT}
out=${2:?usage: below.sh ARCH OUT}
case $arch in
    x86_64 | aarch64) ;;
    *) echo "${0##*/}: no static build for $arch" >&2; exit 1 ;;
esac

static_fetch "below-$BELOW_VERSION.crate" \
    "https://static.crates.io/crates/below/below-$BELOW_VERSION.crate" "$BELOW_SHA256"

echo "below: building $BELOW_VERSION for $arch" >&2
STATIC_ALPINE=1 STATIC_APK="build-base patch clang llvm elfutils-dev zlib-static zstd-static linux-headers" \
    static_run "$arch" "$out" "BELOW_VERSION=$BELOW_VERSION" <<'EOF'
tar -xzf "$SRC/below-$BELOW_VERSION.crate"
mkdir -p wrap
printf '#!/bin/sh\nexec cc "$@" -Wl,-Bstatic -lzstd -lgcc -lc\n' >wrap/zstd-gcc
printf '#!/bin/sh\nexec /usr/bin/clang -Wno-error=incompatible-pointer-types "$@"\n' >wrap/clang
chmod +x wrap/*
export PATH="$PWD/wrap:$PATH"
rust_target="$(uname -m)-unknown-linux-musl"
export "CARGO_TARGET_$(echo "${rust_target//-/_}" | tr a-z A-Z)_LINKER=$PWD/wrap/zstd-gcc"
quiet rustup component add rustfmt
quiet cargo fetch --locked --manifest-path "below-$BELOW_VERSION/Cargo.toml"
for p in "$PATCHES"/below/*.patch; do
    patch -s -d "$(echo "$CARGO_HOME"/registry/src/*/)" -p0 <"$p"
done
quiet cargo install --locked --path "below-$BELOW_VERSION" --target "$rust_target" --root "$PWD/inst"
strip -o "$OUT_FILE" inst/bin/below
EOF
