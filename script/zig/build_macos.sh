#!/usr/bin/env bash
set -euo pipefail

# Build the Zig C ABI for both macOS architectures. The output is deliberately
# outside SwiftPM's .build directory so release packaging can copy and inspect
# it without committing a toolchain or build products.
ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT_DIR"
zig="$(script/zig/bootstrap.sh)"
out="${MISSTYPE_ZIG_MACOS_OUT:-$ROOT_DIR/dist/zig/macos-universal}"
rm -rf "$out" "$ROOT_DIR/dist/zig/macos-x86_64" "$ROOT_DIR/dist/zig/macos-arm64"
mkdir -p "$out"

for arch in x86_64 arm64; do
    case "$arch" in
        x86_64) target=x86_64-macos.13.0; dir="$ROOT_DIR/dist/zig/macos-x86_64" ;;
        arm64) target=aarch64-macos.13.0; dir="$ROOT_DIR/dist/zig/macos-arm64" ;;
    esac
    (cd "$ROOT_DIR/core-zig" && "$zig" build -Dtarget="$target" -Doptimize=ReleaseFast -p "$dir")
done

lipo -create \
    "$ROOT_DIR/dist/zig/macos-x86_64/lib/libMisstypeCAPI.dylib" \
    "$ROOT_DIR/dist/zig/macos-arm64/lib/libMisstypeCAPI.dylib" \
    -output "$out/libMisstypeCAPI.dylib"
cp Sources/CMisstype/include/misstype.h "$out/misstype.h"
lipo -info "$out/libMisstypeCAPI.dylib"
nm -gU "$out/libMisstypeCAPI.dylib" | grep -q ' _misstype_abi_version'
