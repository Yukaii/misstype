#!/usr/bin/env bash
# Disposable native-distro build and package install/remove verification.
set -euo pipefail
mkdir -p /w
# No host caches or build products: all payloads come from this source tree.
tar -C /src --exclude=./.git --exclude=./.cache --exclude=./.build \
    --exclude=./build --exclude=./dist --exclude=./core-zig/.zig-cache \
    --exclude=./core-zig/zig-out -cf - . | tar -C /w -xf -
# Arch makepkg clones the exact checkout, including its tag and commit history.
cp -a /src/.git /w/.git
cd /w
case "$DISTRO" in
ubuntu24.04)
    apt-get update
    apt-get install -y sudo git dpkg-dev fcitx5-config-qt fcitx5-frontend-gtk3 fcitx5-frontend-qt5
    bash script/linux/bootstrap.sh
    script/linux/test_all.sh
    script/linux/package_deb.sh "$VERSION"
    apt-get install -y ./dist/*.deb
    ;;
arch)
    pacman -Syu --noconfirm --needed base-devel git cmake ninja python gtk4 fcitx5 fcitx5-configtool fcitx5-gtk fcitx5-qt
    useradd -m builder
    chown -R builder:builder /w
    # The checkout is trusted only in this disposable build container.
    runuser -u builder -- git config --global --add safe.directory /w
    runuser -u builder -- script/linux/package_arch.sh "$VERSION"
    pacman -U --noconfirm dist/*.pkg.tar.zst
    ;;
fedora43)
    dnf install -y git gcc gcc-c++ cmake make pkgconf-pkg-config extra-cmake-modules gettext python3 curl xz \
        fcitx5 fcitx5-devel gtk4-devel rpm-build fcitx5-configtool fcitx5-gtk fcitx5-qt
    script/linux/test_all.sh
    script/linux/package_rpm.sh "$VERSION"
    dnf install -y ./dist/*.rpm
    ;;
*) echo "Unsupported distro: $DISTRO" >&2; exit 2 ;;
esac
# Check the actual installed payload (not the build tree).
misstypectl --help
library=$(find /usr/lib /usr/lib64 -path '*/misstype/libMisstypeCAPI.so' -print 2>/dev/null | head -n1)
[[ -n $library ]]
ldd "$library" > build/package-dependencies.txt
if grep -E 'not found|libswift' build/package-dependencies.txt; then exit 1; fi
misstypectl dict check
case "$DISTRO" in
ubuntu24.04) apt-get remove -y fcitx5-misstype ;;
arch) pacman -R --noconfirm fcitx5-misstype-git ;;
fedora43) dnf remove -y fcitx5-misstype ;;
esac
[[ ! -e $library ]]
cp dist/Misstype-* /output/
echo "PACKAGE BUILD / INSTALL / REMOVE OK ($DISTRO)"
