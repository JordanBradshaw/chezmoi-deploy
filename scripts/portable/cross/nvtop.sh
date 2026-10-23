#!/usr/bin/env bash
#
# Cross-build nvtop for the Jetsons with their Yocto SDK.
#
# Usage: nvtop.sh ARCH OUT
#
#   Only aarch64 is supported; other arches exit 1 so build.sh skips nvtop.
#   Only the NVIDIA backend is built: it loads the target's libnvidia-ml at
#   runtime, and the other backends would need libdrm and udev. ncurses is
#   linked statically (see sdk.sh).

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

NVTOP_VERSION=3.3.2

cross_require_aarch64 "${1:?usage: nvtop.sh ARCH OUT}"
out=${2:?usage: nvtop.sh ARCH OUT}

cross_fetch "nvtop-$NVTOP_VERSION.tar.gz" \
    "https://github.com/Syllo/nvtop/archive/refs/tags/$NVTOP_VERSION.tar.gz"
cross_fetch_ncurses

cross_run "$out" "NVTOP_VERSION=$NVTOP_VERSION" <<'EOF'
source /cross/sdk.sh
build_ncurses

echo "nvtop: building nvtop $NVTOP_VERSION" >&2
tar -xzf /src/nvtop-$NVTOP_VERSION.tar.gz
backends_off=()
for b in AMDGPU RADEON INTEL MSM APPLE PANFROST PANTHOR ASCEND V3D TPU ROCKCHIP \
    METAX ENFLAME TENSTORRENT IXML; do
    backends_off+=(-D${b}_SUPPORT=OFF)
done
# The OE toolchain file takes C flags from $CFLAGS, not -DCMAKE_C_FLAGS.
# curses.h includes <ncursesw/...>, so the parent include dir is needed too.
export CFLAGS="$CFLAGS -I$PREFIX/include"
quiet cmake -S nvtop-$NVTOP_VERSION -B nvtop-build \
    -DCMAKE_TOOLCHAIN_FILE=$OECORE_NATIVE_SYSROOT/usr/share/cmake/OEToolchainConfig.cmake \
    -DCMAKE_BUILD_TYPE=Release -DNVIDIA_SUPPORT=ON "${backends_off[@]}" \
    -DCURSES_NEED_NCURSES=TRUE -DCURSES_NEED_WIDE=TRUE \
    -DCURSES_INCLUDE_PATH=$PREFIX/include/ncursesw \
    -DCURSES_LIBRARY=$PREFIX/lib/libncursesw.a \
    -DCURSES_NCURSES_LIBRARY=$PREFIX/lib/libncursesw.a
quiet cmake --build nvtop-build -j"$JOBS"
install_binary nvtop-build/src/nvtop
EOF
