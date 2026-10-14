#!/usr/bin/env bash
# Install the pinned Zig toolchain into .cache/zig/<version> (never committed)
# and print its path. Idempotent; verifies the tarball checksum.
#
#   script/zig/bootstrap.sh            # -> .cache/zig/0.17.0/zig
#   "$(script/zig/bootstrap.sh)" build test
set -euo pipefail
cd "$(dirname "$0")/../.."

ZIG_VERSION=0.17.0
if [ -n "${MISSTYPE_ZIG:-}" ]; then
    [ "$("$MISSTYPE_ZIG" version)" = "$ZIG_VERSION" ] || { echo "bootstrap: Zig $ZIG_VERSION required" >&2; exit 1; }
    echo "$MISSTYPE_ZIG"
    exit 0
fi
case "$(uname -s)-$(uname -m)" in
    Linux-x86_64)  triple=x86_64-linux;  sha=1cbe9df9f27e6b78d14ccbca43b6703a404ef79ef1c463de901d7f088d4e2026 ;;
    Linux-aarch64) triple=aarch64-linux; sha=9e8d11661d4ae3bd57702a3832781e23ad151dde5798e16a5ccd503f65234ff8 ;;
    Darwin-x86_64) triple=x86_64-macos;  sha=4f9a1c5269aa17ebda5e6d3c2b89d6cbf36f7d2b22a0306e9ab98f25f95529c6 ;;
    Darwin-arm64)  triple=aarch64-macos; sha=b607e9b9234790a008116ae5bdb71c6243b84b9fb42a53a9e70fde41c06c536a ;;
    MINGW*-x86_64|MSYS*-x86_64) triple=x86_64-windows; ext=zip; sha=b5663f69581dcf391293fbf16c06cb80d81d806545ce618b4d0bab7f0eb8c428 ;;
    MINGW*-aarch64|MSYS*-aarch64|MINGW*-arm64) triple=aarch64-windows; ext=zip; sha=0a59d91fa1cb40cf068e9b0954434ce973500c7a2ea749f1e01af62cdab52d26 ;;
    *) echo "bootstrap: unsupported host $(uname -s)-$(uname -m)" >&2; exit 1 ;;
esac

ext=${ext:-tar.xz}
exe=zig
[ "$ext" = zip ] && exe=zig.exe
dest=.cache/zig/$ZIG_VERSION
if [ ! -x "$dest/$exe" ]; then
    name=zig-$triple-$ZIG_VERSION
    tmp=$(mktemp -d)
    trap 'rm -rf "$tmp"' EXIT
    curl -fsSL --retry 3 -o "$tmp/$name.$ext" "https://ziglang.org/download/$ZIG_VERSION/$name.$ext"
    if command -v sha256sum >/dev/null; then got=$(sha256sum "$tmp/$name.$ext"); else got=$(shasum -a 256 "$tmp/$name.$ext"); fi
    [ "${got%% *}" = "$sha" ] || { echo "bootstrap: checksum mismatch for $name" >&2; exit 1; }
    if [ "$ext" = zip ]; then
        # Git Bash's GNU tar cannot read zip; unzip ships with it and the runner.
        unzip -q "$tmp/$name.zip" -d "$tmp"
    else
        tar -xJf "$tmp/$name.tar.xz" -C "$tmp"
    fi
    mkdir -p "$(dirname "$dest")"
    rm -rf "$dest"
    mv "$tmp/$name" "$dest"
fi
echo "$PWD/$dest/$exe"
