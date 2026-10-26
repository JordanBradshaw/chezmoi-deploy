# Sourced inside the SDK container by the scripts cross_run executes.
#
# Sets up the cross toolchain and provides static ncurses and libevent in
# $PREFIX, so tools need nothing from the target but glibc.

set -euo pipefail
source /opt/nos/environment-setup-armv8a-oe4t-linux >/dev/null

JOBS=$(nproc)
PREFIX=/tmp/prefix
mkdir -p /tmp/build "$PREFIX"
cd /tmp/build

# Only our static libraries, never the sysroot's shared ones.
export PKG_CONFIG_SYSROOT_DIR= PKG_CONFIG_PATH= PKG_CONFIG_LIBDIR=$PREFIX/lib/pkgconfig

# quiet CMD...: run CMD with its output in a log, shown only if it fails.
quiet() {
    "$@" >/tmp/build/log 2>&1 || { tail -40 /tmp/build/log >&2; return 1; }
}

build_libevent() {
    echo "${OUT_NAME}: building libevent $LIBEVENT_VERSION" >&2
    tar -xzf /src/libevent-$LIBEVENT_VERSION.tar.gz
    (cd libevent-$LIBEVENT_VERSION &&
        quiet ./configure $CONFIGURE_FLAGS --prefix=$PREFIX --disable-shared --enable-static \
            --disable-openssl --disable-samples --disable-libevent-regress &&
        quiet make -j"$JOBS" && quiet make install)
}

# Terminfo is looked up in the usual system dirs; zssh's enter adds the
# bundled database through TERMINFO_DIRS.
build_ncurses() {
    echo "${OUT_NAME}: building ncurses $NCURSES_VERSION" >&2
    tar -xzf /src/ncurses-$NCURSES_VERSION.tar.gz
    (cd ncurses-$NCURSES_VERSION &&
        quiet ./configure $CONFIGURE_FLAGS --prefix=$PREFIX --without-shared --with-normal \
            --without-debug --without-ada --without-cxx --without-cxx-binding \
            --without-progs --without-tests --without-manpages --enable-widec \
            --disable-db-install --enable-pc-files --with-pkg-config-libdir=$PREFIX/lib/pkgconfig \
            --with-terminfo-dirs=/etc/terminfo:/usr/share/terminfo:/lib/terminfo:/usr/lib/terminfo \
            --with-default-terminfo-dir=/usr/share/terminfo &&
        quiet make -j"$JOBS" libs && quiet make install.libs install.includes)
}

# install_binary PATH: strip PATH into /out/$OUT_NAME and list its libraries.
install_binary() {
    $STRIP "$1"
    cp "$1" /out/$OUT_NAME
    $READELF -d /out/$OUT_NAME | sed -n "s/.*Shared library: \[\(.*\)\]/${OUT_NAME}: needs \1/p" >&2
}
