#!/usr/bin/env bash
#
# Cross-build tmux for the Jetsons with their Yocto SDK.
#
# Usage: tmux.sh ARCH OUT
#
#   Only aarch64 is supported; other arches exit 1 so build.sh skips tmux.
#   libevent and ncurses are linked statically (see sdk.sh).

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMUX_VERSION=3.5a

cross_require_aarch64 "${1:?usage: tmux.sh ARCH OUT}"
out=${2:?usage: tmux.sh ARCH OUT}

cross_fetch "tmux-$TMUX_VERSION.tar.gz" \
    "https://github.com/tmux/tmux/releases/download/$TMUX_VERSION/tmux-$TMUX_VERSION.tar.gz"
cross_fetch_libevent
cross_fetch_ncurses

cross_run "$out" "TMUX_VERSION=$TMUX_VERSION" <<'EOF'
source /cross/sdk.sh
build_libevent
build_ncurses

echo "tmux: building tmux $TMUX_VERSION" >&2
tar -xzf /src/tmux-$TMUX_VERSION.tar.gz
(cd tmux-$TMUX_VERSION &&
    quiet ./configure $CONFIGURE_FLAGS --prefix=/usr --disable-utf8proc \
        CPPFLAGS="-I$PREFIX/include -I$PREFIX/include/ncursesw" LDFLAGS="-L$PREFIX/lib" &&
    quiet make -j"$JOBS")
install_binary tmux-$TMUX_VERSION/tmux
EOF
