#!/usr/bin/env bash
# Ubuntu 24.04 package; provision with bootstrap.sh plus dpkg-dev first.
# Run Linux checks before invoking this script. Outputs only to ignored dist/.
set -euo pipefail
cd "$(dirname "$0")/../.."
version=${1:?usage: package_deb.sh <version>}
version=${version#v}
[[ $version =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[A-Za-z0-9.]+)?$ ]] || { echo 'Invalid version' >&2; exit 2; }
# Debian sorts prereleases before their stable release.
deb_version=${version/-/~}
arch=$(dpkg --print-architecture)
source /etc/os-release
[[ $ID == ubuntu && $VERSION_ID == 24.04 ]] || { echo 'Build this package on Ubuntu 24.04' >&2; exit 2; }
script/linux/build.sh
stage=$(mktemp -d "$PWD/build/deb.XXXXXX")
trap 'rm -rf "$stage"' EXIT
DESTDIR="$stage" cmake --install build/fcitx5
mkdir -p "$stage/DEBIAN" "$stage/metadata/debian"
cat > "$stage/metadata/debian/control" <<'CONTROL'
Source: fcitx5-misstype
Section: utils
Priority: optional
Maintainer: Misstype contributors <noreply@misstype.yukai.dev>

Package: fcitx5-misstype
Architecture: any
Description: Offline fuzzy Zhuyin input method for fcitx5
CONTROL
# The unversioned private Zig library is shipped in this package. Scan the
# addon and editor for distro dependencies; dpkg ignores unversioned private
# SONAMEs, while still requiring metadata for every system library.
mapfile -t binaries < <(find "$stage/usr" -type f \( -name 'libmisstype-fcitx5.so' -o -name 'misstype-dictionary-editor' \))
private_lib=$(find "$stage/usr" -name libMisstypeCAPI.so -printf '%h\n')
args=()
for binary in "${binaries[@]}"; do args+=(-e"$binary"); done
runtime_deps=$(cd "$stage/metadata" && dpkg-shlibdeps -O -l"$private_lib" "${args[@]}")
runtime_deps=${runtime_deps#shlibs:Depends=}
rm -r "$stage/metadata"
cat > "$stage/DEBIAN/control" <<CONTROL
Package: fcitx5-misstype
Version: $deb_version
Architecture: $arch
Section: utils
Priority: optional
Maintainer: Misstype contributors <noreply@misstype.yukai.dev>
Depends: fcitx5, $runtime_deps
Recommends: fcitx5-config-qt, fcitx5-frontend-gtk3, fcitx5-frontend-qt5
Homepage: https://github.com/Yukaii/misstype
Description: Offline fuzzy Zhuyin input method for fcitx5
 Optional tones, automatic typo repair, local phrase learning and a user
 dictionary, using the same Zig core as the macOS input method.
CONTROL
mkdir -p dist
package="Misstype-$version-ubuntu24.04-$arch.deb"
dpkg-deb --root-owner-group --build "$stage" "dist/$package"
(cd dist && sha256sum "$package" > "$package.sha256")
echo "Built dist/$package"
