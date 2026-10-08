#!/usr/bin/env bash
# Builds the shipping Zig core and CLI. MISSTYPE_CORE=swift selects the
# reference backend. Both record their directory in build/capi/libdir.
set -euo pipefail
cd "$(dirname "$0")/../.."

case "${MISSTYPE_CORE:-zig}" in
zig)
    zig=$(script/zig/bootstrap.sh)
    (cd core-zig && "$zig" build linux -Doptimize="${MISSTYPE_ZIG_OPTIMIZE:-ReleaseFast}")
    BIN_DIR="$PWD/build/zig-capi"
    mkdir -p "$BIN_DIR"
    cp core-zig/zig-out/lib/libMisstypeCAPI.so core-zig/zig-out/bin/misstypectl "$BIN_DIR/"
    ;;
swift)
    swift build -c release --product MisstypeCAPI -Xswiftc -static-stdlib \
        -Xlinker -soname=libMisstypeCAPI.so 2>&1
    BIN_DIR=$(swift build -c release --show-bin-path)
    test -f "$BIN_DIR/libMisstypeCAPI.so"
    # The settings/dictionary CLI ships next to the library (cmake installs it).
    swift build -c release --product misstypectl -Xswiftc -static-stdlib 2>&1
    test -f "$BIN_DIR/misstypectl"
    ;;
*) echo "build_capi: MISSTYPE_CORE must be zig or swift" >&2; exit 1 ;;
esac
mkdir -p build/capi
echo "$BIN_DIR" > build/capi/libdir
echo "libMisstypeCAPI.so: $BIN_DIR"
