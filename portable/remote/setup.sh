#!/bin/sh
#
# Run on the target after unpacking a bundle, before it is moved into place.
#
# Usage: sh setup.sh FINAL_APP_DIR
#
# Points zsh-bin's hard-coded paths at FINAL_APP_DIR/zsh and disables any
# bundled tool that can't run here (e.g. a glibc build on an older distro),
# so the shell config falls back to the system's tools instead.

set -eu

here=$(cd "$(dirname "$0")" && pwd)
dest=$1

for relocate in "$here"/zsh/share/zsh/*/scripts/relocate; do
    [ -f "$relocate" ] || continue
    sh "$relocate" -s "$here/zsh" -d "$dest/zsh"
done

# Only the loader's own failures mean a tool can't run: wrong CPU (126),
# missing interpreter or library (127), or a glibc that is too old. A tool
# that starts and then complains (tegratop off a Jetson) stays.
mkdir -p "$here/bin/.disabled"
# Tools may write config or caches when they start (lnav makes ~/.lnav), so
# probe them with a throwaway home inside the bundle.
probe=$here/.probe-home
rm -rf "$probe"
mkdir -p "$probe"
for tool in "$here"/bin/*; do
    [ -f "$tool" ] || continue
    name=${tool##*/}
    rc=0
    err=$(HOME=$probe XDG_CONFIG_HOME=$probe/config XDG_CACHE_HOME=$probe/cache \
        XDG_DATA_HOME=$probe/data XDG_STATE_HOME=$probe/state \
        "$tool" --version 2>&1 >/dev/null </dev/null) || rc=$?
    case $rc:$err in
        126:* | 127:* | *"version \`GLIBC_"*"' not found"* | *"error while loading shared libraries"*)
            mv "$tool" "$here/bin/.disabled/$name"
            echo "zsh-portable: $name can't run on this host, disabled" >&2
            ;;
    esac
done
rm -rf "$probe"
