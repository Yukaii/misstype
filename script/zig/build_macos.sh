#!/usr/bin/env bash
set -euo pipefail

# Build the Zig C ABI for macOS. By default this produces both slices for
# release packaging. Set MISSTYPE_MACOS_ARCH=native for a local build that
# only targets the architecture running the build (the install script uses
# this mode on Apple Silicon and Intel Macs).
ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT_DIR"
zig="$(script/zig/bootstrap.sh)"
out="${MISSTYPE_ZIG_MACOS_OUT:-$ROOT_DIR/dist/zig/macos-universal}"
requested_arch="${MISSTYPE_MACOS_ARCH:-universal}"
rm -rf "$out" "$ROOT_DIR/dist/zig/macos-x86_64" "$ROOT_DIR/dist/zig/macos-arm64"
mkdir -p "$out"

if [[ "$requested_arch" == native ]]; then
    host_arch="$(uname -m)"
    case "$host_arch" in
        arm64|aarch64) archs=(arm64) ;;
        x86_64|amd64) archs=(x86_64) ;;
        *) echo "Unsupported macOS host architecture: $host_arch" >&2; exit 1 ;;
    esac
elif [[ "$requested_arch" == universal ]]; then
    archs=(x86_64 arm64)
else
    case "$requested_arch" in
        x86_64|arm64) archs=("$requested_arch") ;;
        *) echo "MISSTYPE_MACOS_ARCH must be universal, native, x86_64, or arm64" >&2; exit 1 ;;
    esac
fi

for arch in "${archs[@]}"; do
    case "$arch" in
        x86_64) target=x86_64-macos.13.0; dir="$ROOT_DIR/dist/zig/macos-x86_64" ;;
        arm64) target=aarch64-macos.13.0; dir="$ROOT_DIR/dist/zig/macos-arm64" ;;
    esac
    (cd "$ROOT_DIR/core-zig" && "$zig" build -Dtarget="$target" -Doptimize=ReleaseFast -p "$dir")
done

if (( ${#archs[@]} == 1 )); then
    cp "$ROOT_DIR/dist/zig/macos-${archs[0]}/lib/libMisstypeCAPI.dylib" \
       "$out/libMisstypeCAPI.dylib"
else
    lipo -create \
        "$ROOT_DIR/dist/zig/macos-x86_64/lib/libMisstypeCAPI.dylib" \
        "$ROOT_DIR/dist/zig/macos-arm64/lib/libMisstypeCAPI.dylib" \
        -output "$out/libMisstypeCAPI.dylib"
fi
cp Sources/CMisstype/include/misstype.h "$out/misstype.h"
lipo -info "$out/libMisstypeCAPI.dylib"
nm -gU "$out/libMisstypeCAPI.dylib" | grep -q ' _misstype_abi_version'
