#!/usr/bin/env bash
# Run as a normal user on Arch with the PKGBUILD dependencies installed.
# Builds the exact committed checkout (including private repositories).
set -euo pipefail
cd "$(dirname "$0")/../.."
version=${1:?usage: package_arch.sh <version>}
version=${version#v}
[[ $version =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[A-Za-z0-9.]+)?$ ]] || { echo 'Invalid version' >&2; exit 2; }
root=$PWD
mkdir -p build dist
work=$(mktemp -d "$PWD/build/arch-release.XXXXXX")
trap 'rm -rf "$work"' EXIT
cp linux/aur/{PKGBUILD,cxx20.patch} "$work/"
export MISSTYPE_SOURCE_URL="file://$root#commit=$(git rev-parse HEAD)"
export PKGEXT=.pkg.tar.zst
(cd "$work" && makepkg --cleanbuild --force)
package=$(cd "$work" && makepkg --packagelist)
[[ -f $package ]]
asset="Misstype-$version-arch-$(uname -m).pkg.tar.zst"
cp "$package" "dist/$asset"
(cd dist && sha256sum "$asset" > "$asset.sha256")
echo "Built dist/$asset"
