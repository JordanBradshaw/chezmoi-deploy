# Static libraries for static/*.sh recipes, sourced by a recipe inside
# static_run (as "$DEPS"). Each builds into $PREFIX from its tarball in $SRC,
# which the recipe fetches on the host first (static_fetch_ncurses,
# static_fetch_libpcap in lib.sh).

PREFIX=$PWD/deps
mkdir -p "$PREFIX"
export CPPFLAGS="-I$PREFIX/include -I$PREFIX/include/ncursesw" LDFLAGS="-L$PREFIX/lib"

# The host's terminfo dirs; ncurses has no database of its own here. Wide
# character only, also linkable as -lncurses and -lcurses.
build_ncurses() {
    echo "static: building ncurses $NCURSES_VERSION" >&2
    tar -xzf "$SRC/ncurses-$NCURSES_VERSION.tar.gz"
    (cd "ncurses-$NCURSES_VERSION" &&
        quiet ./configure --host="$TARGET" --prefix="$PREFIX" --without-shared --with-normal \
            --without-debug --without-ada --without-cxx --without-cxx-binding \
            --without-progs --without-tests --without-manpages --enable-widec \
            --disable-db-install --disable-stripping \
            --with-terminfo-dirs=/etc/terminfo:/usr/share/terminfo:/lib/terminfo:/usr/lib/terminfo \
            --with-default-terminfo-dir=/usr/share/terminfo &&
        quiet make -j"$JOBS" libs && quiet make install.libs install.includes)
    ln -sf libncursesw.a "$PREFIX/lib/libncurses.a"
    ln -sf libncursesw.a "$PREFIX/lib/libcurses.a"
}

# Without D-Bus, RDMA, Bluetooth and netfilter capture: interfaces only.
build_libpcap() {
    echo "static: building libpcap $LIBPCAP_VERSION" >&2
    tar -xJf "$SRC/libpcap-$LIBPCAP_VERSION.tar.xz"
    (cd "libpcap-$LIBPCAP_VERSION" &&
        quiet ./configure --host="$TARGET" --prefix="$PREFIX" --disable-shared \
            --disable-usb --disable-netmap --disable-bluetooth --disable-dbus --disable-rdma \
            --without-libnl --without-dpdk &&
        quiet make -j"$JOBS" && quiet make install)
}
