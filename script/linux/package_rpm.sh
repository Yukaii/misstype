#!/usr/bin/env bash
# Fedora package; install the build dependencies listed in release.yml first.
# rpmbuild derives shared-library requirements and provides from the payload.
set -euo pipefail
cd "$(dirname "$0")/../.."
version=${1:?usage: package_rpm.sh <version>}
version=${version#v}
[[ $version =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[A-Za-z0-9.]+)?$ ]] || { echo 'Invalid version' >&2; exit 2; }
source /etc/os-release
[[ $ID == fedora ]] || { echo 'Build this package on Fedora' >&2; exit 2; }
rpm_version=${version%%-*}
release=1
[[ $version != *-* ]] || release="0.1.${version#*-}"
script/linux/build.sh
work=$(mktemp -d "$PWD/build/rpm.XXXXXX")
trap 'rm -rf "$work"' EXIT
mkdir -p "$work"/{BUILD,BUILDROOT,RPMS,SOURCES,SPECS,SRPMS,payload}
DESTDIR="$work/payload" cmake --install build/fcitx5
find "$work/payload/usr" -type f -printf '/usr/%P\n' | sort > "$work/files"
cat > "$work/SPECS/misstype.spec" <<SPEC
Name: fcitx5-misstype
Version: $rpm_version
Release: $release%{?dist}
Summary: Offline fuzzy Zhuyin input method for fcitx5
License: MIT AND BSD-3-Clause AND CC-BY-4.0 AND CC-BY-SA-4.0 AND Unicode-3.0
URL: https://github.com/Yukaii/misstype
Requires: fcitx5
Recommends: fcitx5-configtool, fcitx5-gtk, fcitx5-qt
# Zig supplies optimized binaries without split debug information.
%global debug_package %{nil}
%description
Optional tones, automatic typo repair, local phrase learning and a user
 dictionary, using the same Zig core as the macOS input method.
%install
mkdir -p %{buildroot}
cp -a $work/payload/. %{buildroot}/
%files -f $work/files
SPEC
rpmbuild --define "_topdir $work" -bb "$work/SPECS/misstype.spec"
mapfile -t packages < <(find "$work/RPMS" -name '*.rpm')
[[ ${#packages[@]} == 1 ]]
asset="Misstype-$version-fedora$VERSION_ID-$(uname -m).rpm"
mkdir -p dist
cp "${packages[0]}" "dist/$asset"
(cd dist && sha256sum "$asset" > "$asset.sha256")
echo "Built dist/$asset"
