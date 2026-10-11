#!/usr/bin/env python3
"""Pin a binary recipe to a downloaded, checksum-verified stable release.

The caller verifies GitHub provenance before invoking this script. This script
never executes PKGBUILD; makepkg generates .SRCINFO in a separate container.
"""
import argparse
import hashlib
from pathlib import Path
import re


def prepare(recipe: Path, assets: Path, tag: str, output: Path):
    if not re.fullmatch(r"v[0-9]+\.[0-9]+\.[0-9]+", tag):
        raise ValueError("Expected a stable vMAJOR.MINOR.PATCH tag")
    names = {"aur-fcitx5-bin": "Misstype", "aur-ibus-bin": "MisstypeIBus"}
    prefix = names[recipe.name]
    asset = f"{prefix}-{tag[1:]}-arch-x86_64.pkg.tar.zst"
    checksum = (assets / (asset + ".sha256")).read_text().strip()
    match = re.fullmatch(r"([0-9a-f]{64}) [ *]" + re.escape(asset), checksum)
    if not match:
        raise ValueError("Checksum must identify exactly the requested release asset")
    with (assets / asset).open("rb") as payload:
        digest = hashlib.file_digest(payload, "sha256").hexdigest()
    if digest != match[1]:
        raise ValueError("Release asset checksum mismatch")
    text = (recipe / "PKGBUILD").read_text()
    for pattern, replacement in (
        (r"^pkgver=.*$", f"pkgver={tag[1:]}"),
        (r"^pkgrel=.*$", "pkgrel=1"),
        (r"^sha256sums=.*$", f"sha256sums=('{digest}')"),
    ):
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
