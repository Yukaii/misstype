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
    script/linux/package_deb.sh "$VERSION" ibus
    ;;
arch)
    pacman -Syu --noconfirm --needed base-devel git cmake ninja python gtk4 fcitx5 fcitx5-configtool fcitx5-gtk fcitx5-qt ibus
    useradd -m builder
    chown -R builder:builder /w
    # The checkout is trusted only in this disposable build container.
    runuser -u builder -- git config --global --add safe.directory /w
    runuser -u builder -- script/linux/package_arch.sh "$VERSION"
    runuser -u builder -- script/linux/package_arch.sh "$VERSION" ibus
    ;;
fedora43)
    dnf install -y git gcc gcc-c++ cmake make pkgconf-pkg-config extra-cmake-modules gettext python3 curl xz \
        fcitx5 fcitx5-devel gtk4-devel rpm-build fcitx5-configtool fcitx5-gtk fcitx5-qt \
        ibus ibus-devel glib2-devel xorg-x11-server-Xvfb dbus-x11 dbus-daemon
    script/linux/test_all.sh
    script/linux/package_rpm.sh "$VERSION"
    script/linux/package_rpm.sh "$VERSION" ibus
    ;;
*) echo "Unsupported distro: $DISTRO" >&2; exit 2 ;;
esac
# Install, check and remove one package: the actual installed payload, not the
# build tree. The fcitx5 and IBus packages conflict, so they go one at a time.
verify() {
    local flavor=$1
    case "$DISTRO:$flavor" in
    ubuntu24.04:fcitx5) apt-get install -y ./dist/Misstype-*.deb ;;
    ubuntu24.04:ibus) apt-get install -y ./dist/MisstypeIBus-*.deb ;;
    arch:fcitx5) pacman -U --noconfirm dist/Misstype-*.pkg.tar.zst ;;
    arch:ibus) pacman -U --noconfirm dist/MisstypeIBus-*.pkg.tar.zst ;;
    fedora43:fcitx5) dnf install -y ./dist/Misstype-*.rpm ;;
    fedora43:ibus) dnf install -y ./dist/MisstypeIBus-*.rpm ;;
    esac
    misstypectl --help
    library=$(find /usr/lib /usr/lib64 -path '*/misstype/libMisstypeCAPI.so' -print 2>/dev/null | head -n1)
    [[ -n $library ]]
    ldd "$library" > build/package-dependencies.txt
    if grep -E 'not found|libswift' build/package-dependencies.txt; then exit 1; fi
    misstypectl dict check
    if [[ $flavor == ibus ]]; then
        # Component XML points at an engine whose libraries all resolve, and
        # the settings tool it declares exists.
        component=/usr/share/ibus/component/misstype.xml
        [[ -f $component ]]
        engine=$(sed -n 's|.*<exec>\([^ <]*\).*|\1|p' "$component")
        [[ -x $engine ]]
        if ldd "$engine" | grep 'not found'; then exit 1; fi
        setup=$(sed -n 's|.*<setup>\([^<]*\)</setup>|\1|p' "$component")
        [[ -z $setup || -x $setup ]]
    fi
    case "$DISTRO:$flavor" in
    ubuntu24.04:fcitx5) apt-get remove -y fcitx5-misstype ;;
    ubuntu24.04:ibus) apt-get remove -y ibus-misstype ;;
    arch:fcitx5) pacman -R --noconfirm fcitx5-misstype-git ;;
    arch:ibus) pacman -R --noconfirm ibus-misstype-git ;;
    fedora43:fcitx5) dnf remove -y fcitx5-misstype ;;
    fedora43:ibus) dnf remove -y ibus-misstype ;;
    esac
    [[ ! -e $library ]]
}
verify fcitx5
verify ibus
cp dist/Misstype-* dist/MisstypeIBus-* /output/
echo "PACKAGE BUILD / INSTALL / REMOVE OK ($DISTRO)"
