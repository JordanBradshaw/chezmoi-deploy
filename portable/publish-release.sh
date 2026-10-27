#!/usr/bin/env bash
# Usage: publish-release.sh DIST_DIR
# Publishes the dev bundle to the rolling `bundles` release and an immutable
# bundle-dev-<date>-<version> release. Needs gh, GH_TOKEN and GITHUB_REPOSITORY.
set -euo pipefail

dist=${1:?usage: publish-release.sh DIST_DIR}
name=zsh-portable-dev-x86_64
tarball=$dist/$name.tar.gz
versionfile=$dist/$name.version
[[ -f $tarball && -f $versionfile ]] || { echo "missing bundle in $dist" >&2; exit 1; }

version=$(tr -d '[:space:]' <"$versionfile")
previous=$(gh release download bundles -p "$name.version" -O - 2>/dev/null | tr -d '[:space:]' || true)
if [[ -n $previous && $previous == "$version" ]]; then
    echo "version $version unchanged; nothing to publish"
    exit 0
fi

if [[ -n ${PUBLISH_GATE:-} ]]; then
    FEATURE_E2E=1 FEATURE_BUNDLE=$tarball bash "$PUBLISH_GATE"
fi

(cd "$dist" && sha256sum "$name.tar.gz" >SHA256SUMS)
tar -xOzf "$tarball" ./BUILDINFO >"$dist/BUILDINFO"
assets=("$tarball" "$versionfile" "$dist/SHA256SUMS" "$dist/BUILDINFO")

if gh release view bundles >/dev/null 2>&1; then
    gh release upload bundles "${assets[@]}" --clobber
else
    gh release create bundles --prerelease --title "Rolling dev bundle" \
        --notes "Latest portable dev bundle (rolling). Pinned builds: bundle-dev-* releases." \
        "${assets[@]}"
fi

tag=bundle-dev-$(date -u +%F)-$version
if gh release view "$tag" >/dev/null 2>&1; then
    echo "$tag already exists; skipping"
else
    gh release create "$tag" --title "Dev bundle $version" --notes "Immutable dev bundle $version." "${assets[@]}"
fi
