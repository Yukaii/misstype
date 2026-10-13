#!/usr/bin/env bash
# Run as root in disposable current Arch; never builds Misstype or Zig.
# source-root must be the release tag's tree (headers, drivers, expected output
# and adapter conformance fixtures), not the workflow branch's tree.
set -euo pipefail
package=${1:?usage: test_aur_bin.sh <prepared-directory> <assets-directory> <source-root>}
assets=${2:?}
root=${3:?}
# Arch container images omit documentation by default; verify the full payload.
sed -i '/^NoExtract[[:space:]]*=/d' /etc/pacman.conf
case $(sed -n 's/^pkgname=//p' "$package/PKGBUILD") in
fcitx5-misstype-bin) frontend=fcitx5 ;;
ibus-misstype-bin) frontend=ibus ;;
*) echo 'Unknown binary package' >&2; exit 1 ;;
esac
if [[ $(uname -m) == aarch64 ]]; then
    # Arch Linux ARM rootfs: trust its keyring, skip free-space checks and the
    # board kernel packages a container does not need.
    pacman-key --init
    pacman-key --populate archlinuxarm
    sed -i 's/^CheckSpace/#CheckSpace/' /etc/pacman.conf
    # pacman's download sandbox needs Landlock, which the runner's container denies.
    sed -i '/^\[options\]/a DisableSandbox' /etc/pacman.conf
    pacman -Rdd --noconfirm linux-aarch64 linux-aarch64-headers 2>/dev/null || true
fi
pacman -Syu --noconfirm --needed base-devel python "$frontend" gtk4 cmake extra-cmake-modules \
    xorg-server-xvfb xorg-xauth dbus
id builder >/dev/null 2>&1 || useradd -m builder
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
cp "$package/PKGBUILD" "$assets/"*-arch-"$(uname -m)".pkg.tar.zst "$work/"
chown -R builder:builder "$work"
cd "$work"
runuser -u builder -- makepkg --printsrcinfo > "$package/.SRCINFO"
runuser -u builder -- makepkg --cleanbuild --force --noconfirm
binary=$(runuser -u builder -- makepkg --packagelist)
name=$(pacman -Qip "$binary" | sed -n 's/^Name *: //p')
[[ $name == fcitx5-misstype-bin || $name == ibus-misstype-bin ]]
pacman -U --noconfirm "$binary"
pacman -Qkk "$name"
pacman -Qlp "$binary"
# Compare payload paths after the sole intentional change: license directory.
case $name in
fcitx5-misstype-bin) original=("$assets/"Misstype-*-arch-"$(uname -m)".pkg.tar.zst) ;;
ibus-misstype-bin) original=("$assets/"MisstypeIBus-*-arch-"$(uname -m)".pkg.tar.zst) ;;
esac
[[ ${#original[@]} == 1 ]]
tar -tf "${original[0]}" | sed -n '/^usr\//p' | sed "s/${name%-bin}-git/$name/g" | sort > expected-files
tar -tf "$binary" | sed -n '/^usr\//p' | sort > actual-files
diff -u expected-files actual-files
# Resolve every ELF runtime dependency, including the adapter and GTK tools.
while IFS= read -r file; do
    if [[ -f $file ]] && readelf -h "$file" >/dev/null 2>&1; then
        ldd "$file" > dependencies.txt
        cat dependencies.txt
        if grep -q 'not found' dependencies.txt; then exit 1; fi
        # Record Arch owners of the resolved libraries for dependency review.
        sed -n 's/.*=> \(\/[^ ]*\).*/\1/p' dependencies.txt | xargs -r pacman -Qo
    fi
done < <(pacman -Qlq "$name")
misstypectl --help
misstypectl dict check
python "$root/tests/capi/ctl_test.py" /usr/bin/misstypectl
# Exercise the installed core's editing/session ABI, not a newly built core.
cc -std=c11 -Wall -Wextra -Werror -I"$root/Sources/CMisstype/include" \
    "$root/tests/capi/smoke.c" -L/usr/lib/misstype -lMisstypeCAPI \
    -Wl,-rpath,/usr/lib/misstype -o smoke
./smoke "$root/tests/fixtures/lexicon" | diff -u "$root/tests/capi/expected.txt" -
if [[ $frontend == fcitx5 ]]; then
    cmake -S "$root/tests/aur-bin" -B conformance -DCMAKE_INSTALL_PREFIX=/usr
    cmake --build conformance
    MISSTYPE_RESOURCES="$root/tests/fixtures/lexicon" ./conformance/testmisstype
else
    mkdir -p ibus-conformance/{build/ibus,script/linux}
    ln -s "$root/tests" ibus-conformance/tests
    ln -s /usr/libexec/ibus-engine-misstype ibus-conformance/build/ibus/ibus-engine-misstype
    cp "$root/script/linux/test_ibus.sh" ibus-conformance/script/linux/
    # pkg-config's compiler flags intentionally expand into separate arguments.
    # shellcheck disable=SC2046
    cc "$root/linux/ibus/test/test_ibus.c" $(pkg-config --cflags --libs ibus-1.0) \
        -o ibus-conformance/build/ibus/test-misstype-ibus
    # The Arch Linux ARM rootfs ships an empty file, which --ensure leaves alone.
    [[ -s /etc/machine-id ]] || dbus-uuidgen > /etc/machine-id
    xvfb-run -a dbus-run-session -- bash ibus-conformance/script/linux/test_ibus.sh --inner
fi
pacman -Rns --noconfirm "$name"
[[ ! -e /usr/lib/misstype/libMisstypeCAPI.so && ! -e /usr/bin/misstypectl ]]
echo 'BINARY AUR BUILD / PAYLOAD / DEPENDENCIES / C ABI / CONFORMANCE / INSTALL / REMOVE OK'
