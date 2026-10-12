#!/usr/bin/env python3
"""Pin a binary recipe to a downloaded, checksum-verified stable release.

The caller verifies GitHub provenance before invoking this script. This script
never executes PKGBUILD; makepkg generates .SRCINFO in a separate container.
"""
import argparse
import hashlib
from pathlib import Path
import re


ARCHES = ("x86_64", "aarch64")


def pinned_digest(assets: Path, asset: str) -> str:
    checksum = (assets / (asset + ".sha256")).read_text().strip()
    match = re.fullmatch(r"([0-9a-f]{64}) [ *]" + re.escape(asset), checksum)
    if not match:
        raise ValueError("Checksum must identify exactly the requested release asset")
    with (assets / asset).open("rb") as payload:
        digest = hashlib.file_digest(payload, "sha256").hexdigest()
    if digest != match[1]:
        raise ValueError("Release asset checksum mismatch")
    return digest


def prepare(recipe: Path, assets: Path, tag: str, output: Path):
    if not re.fullmatch(r"v[0-9]+\.[0-9]+\.[0-9]+", tag):
        raise ValueError("Expected a stable vMAJOR.MINOR.PATCH tag")
    names = {"aur-fcitx5-bin": "Misstype", "aur-ibus-bin": "MisstypeIBus"}
    prefix = names[recipe.name]
    # x86_64 is always required; releases cut before aarch64 packaging lack that
    # asset, so the recipe then drops the architecture instead of pinning nothing.
    digests = {}
    for arch in ARCHES:
        asset = f"{prefix}-{tag[1:]}-arch-{arch}.pkg.tar.zst"
        if arch != "x86_64" and not (assets / asset).exists():
            continue
        digests[arch] = pinned_digest(assets, asset)
    text = (recipe / "PKGBUILD").read_text()
    edits = [
        (r"^pkgver=.*$", f"pkgver={tag[1:]}"),
        (r"^pkgrel=.*$", "pkgrel=1"),
        (r"^arch=.*$", "arch=(" + " ".join(f"'{a}'" for a in digests) + ")"),
    ]
    for arch in ARCHES:
        if arch in digests:
            edits.append((rf"^sha256sums_{arch}=.*$", f"sha256sums_{arch}=('{digests[arch]}')"))
        else:
            # The comment above sha256sums_<arch> goes with the dropped lines.
            edits.append((rf"^source_{arch}=.*\n(?:#.*\n)?sha256sums_{arch}=.*\n", ""))
    for pattern, replacement in edits:
        text, count = re.subn(pattern, replacement, text, flags=re.MULTILINE)
        if count != 1:
            raise ValueError(f"Expected exactly one {pattern} field")
    output.mkdir(parents=True, exist_ok=True)
    (output / "PKGBUILD").write_text(text)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("recipe", type=Path)
    parser.add_argument("assets", type=Path)
    parser.add_argument("tag")
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    prepare(args.recipe, args.assets, args.tag, args.output)
