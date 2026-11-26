#!/usr/bin/env bash
# Run as a normal user on Arch with the PKGBUILD dependencies installed.
# Builds the exact committed checkout (including private repositories).
# usage: package_arch.sh <version> [fcitx5|ibus]   (default fcitx5)
set -euo pipefail
cd "$(dirname "$0")/../.."
version=${1:?usage: package_arch.sh <version> [fcitx5|ibus]}
flavor=${2:-fcitx5}
version=${version#v}
[[ $version =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[A-Za-z0-9.]+)?$ ]] || { echo 'Invalid version' >&2; exit 2; }
case $flavor in
fcitx5) recipe=linux/aur; extra=(linux/aur/cxx20.patch); prefix=Misstype ;;
ibus) recipe=linux/aur-ibus; extra=(); prefix=MisstypeIBus ;;
*) echo "Unknown flavor: $flavor" >&2; exit 2 ;;
esac
root=$PWD
mkdir -p build dist
export SRCDEST="${SRCDEST:-$root/build/arch-srcdest}"
mkdir -p "$SRCDEST"
# Pre-seed verified lexicon files from .cache/ when available so makepkg avoids
# redundant downloads across fcitx5 and ibus runs.
for f in BPMFBase.txt BPMFMappings.txt phrase.occ heterophony1.list heterophony2.list heterophony3.list; do
    [[ -f "$root/.cache/mcbopomofo/$f" && ! -e "$SRCDEST/$f" ]] && cp "$root/.cache/mcbopomofo/$f" "$SRCDEST/$f"
done
[[ -f "$root/.cache/mcbopomofo/LICENSE.txt" && ! -e "$SRCDEST/mcbopomofo-LICENSE.txt" ]] && cp "$root/.cache/mcbopomofo/LICENSE.txt" "$SRCDEST/mcbopomofo-LICENSE.txt"
[[ -f "$root/.cache/mcbopomofo/README.md" && ! -e "$SRCDEST/mcbopomofo-README.md" ]] && cp "$root/.cache/mcbopomofo/README.md" "$SRCDEST/mcbopomofo-README.md"
[[ -f "$root/.cache/naer/frequency.tsv" && ! -e "$SRCDEST/frequency.tsv" ]] && cp "$root/.cache/naer/frequency.tsv" "$SRCDEST/frequency.tsv"
[[ -f "$root/.cache/frequencywords/en_50k.txt" && ! -e "$SRCDEST/en_50k.txt" ]] && cp "$root/.cache/frequencywords/en_50k.txt" "$SRCDEST/en_50k.txt"
work=$(mktemp -d "$PWD/build/arch-release.XXXXXX")
trap 'rm -rf "$work"' EXIT
cp "$recipe/PKGBUILD" "${extra[@]}" "$work/"
export MISSTYPE_SOURCE_URL="file://$root#commit=$(git rev-parse HEAD)"
export PKGEXT=.pkg.tar.zst
(cd "$work" && makepkg --cleanbuild --force)
package=$(cd "$work" && makepkg --packagelist)
[[ -f $package ]]
asset="$prefix-$version-arch-$(uname -m).pkg.tar.zst"
cp "$package" "dist/$asset"
(cd dist && sha256sum "$asset" > "$asset.sha256")
echo "Built dist/$asset"
