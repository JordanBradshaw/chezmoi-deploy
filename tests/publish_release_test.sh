#!/usr/bin/env bash
# Tests portable/publish-release.sh with a stubbed gh.
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/dist" "$tmp/src"
echo "built" >"$tmp/src/BUILDINFO"
tar -czf "$tmp/dist/zsh-portable-dev-x86_64.tar.gz" -C "$tmp/src" ./BUILDINFO
echo "v1" >"$tmp/dist/zsh-portable-dev-x86_64.version"
cat >"$tmp/bin/gh" <<'STUB'
#!/usr/bin/env bash
echo "gh $*" >>"$GH_LOG"
case "$1 $2" in
    "release download") [[ -n ${GH_PREV:-} ]] && { echo "$GH_PREV"; exit 0; }; exit 1 ;;
    "release view") [[ " ${GH_EXISTS:-} " == *" $3 "* ]] ;;
esac
STUB
chmod +x "$tmp/bin/gh"
export PATH="$tmp/bin:$PATH" GH_LOG="$tmp/log"
fail() { echo "FAIL: $*" >&2; exit 1; }
run() { : >"$GH_LOG"; bash "$here/portable/publish-release.sh" "$tmp/dist" >/dev/null; }

GH_PREV="" GH_EXISTS="" run
grep -q "release create bundles --prerelease" "$GH_LOG" || fail "first run creates bundles"
grep -q "release create bundle-dev-.*-v1 " "$GH_LOG" || fail "immutable release"
grep -qx "[0-9a-f]\{64\}  zsh-portable-dev-x86_64.tar.gz" "$tmp/dist/SHA256SUMS" || fail "SHA256SUMS"

GH_PREV=v0 GH_EXISTS=bundles run
grep -q "release upload bundles .* --clobber" "$GH_LOG" || fail "upload clobber"

GH_PREV=v1 GH_EXISTS=bundles run
! grep -q "release upload\|release create" "$GH_LOG" || fail "unchanged version publishes"

GH_PREV=v0 GH_EXISTS="bundles bundle-dev-$(date -u +%F)-v1" run
! grep -q "release create" "$GH_LOG" || fail "existing immutable not skipped"
echo "publish_release_test: ok"
