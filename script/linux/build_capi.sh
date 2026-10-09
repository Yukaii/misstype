#!/usr/bin/env bash
# Builds the shipping Zig core (libMisstypeCAPI.so) and misstypectl, and
# records their directory in build/capi/libdir.
set -euo pipefail
cd "$(dirname "$0")/../.."

zig=$(script/zig/bootstrap.sh)
(cd core-zig && "$zig" build linux -Doptimize="${MISSTYPE_ZIG_OPTIMIZE:-ReleaseFast}")
BIN_DIR="$PWD/build/zig-capi"
mkdir -p "$BIN_DIR"
cp core-zig/zig-out/lib/libMisstypeCAPI.so core-zig/zig-out/bin/misstypectl "$BIN_DIR/"
mkdir -p build/capi
echo "$BIN_DIR" > build/capi/libdir
echo "libMisstypeCAPI.so: $BIN_DIR"
