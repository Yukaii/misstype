#!/usr/bin/env bash
# Builds the shipping Zig core (libMisstypeCAPI.so) and misstypectl, and
# records their directory in build/capi/libdir.
set -euo pipefail
cd "$(dirname "$0")/../.."

BIN_DIR="$PWD/build/zig-capi"
mkdir -p "$BIN_DIR"
if [[ -n "${MISSTYPE_PREBUILT_CAPI_DIR:-}" ]]; then
    [[ -f "$MISSTYPE_PREBUILT_CAPI_DIR/libMisstypeCAPI.so" && -x "$MISSTYPE_PREBUILT_CAPI_DIR/misstypectl" ]] || {
        echo "build_capi: MISSTYPE_PREBUILT_CAPI_DIR ($MISSTYPE_PREBUILT_CAPI_DIR) missing libMisstypeCAPI.so or misstypectl" >&2
        exit 1
    }
    cp "$MISSTYPE_PREBUILT_CAPI_DIR/libMisstypeCAPI.so" "$MISSTYPE_PREBUILT_CAPI_DIR/misstypectl" "$BIN_DIR/"
else
    zig=$(script/zig/bootstrap.sh)
    (cd core-zig && ../script/ci/time.sh zig-linux-build "$zig" build linux -Doptimize="${MISSTYPE_ZIG_OPTIMIZE:-ReleaseFast}")
    cp core-zig/zig-out/lib/libMisstypeCAPI.so core-zig/zig-out/bin/misstypectl "$BIN_DIR/"
fi
mkdir -p build/capi
echo "$BIN_DIR" > build/capi/libdir
echo "libMisstypeCAPI.so: $BIN_DIR"
