#!/usr/bin/env bash
# Builds libMisstypeCAPI.so (release, self-contained Swift runtime) and records
# its directory in build/capi/libdir. Shared by test_capi.sh, test_fcitx5.sh
# and build.sh. Runs inside the Linux container (or any Linux with Swift 6).
set -euo pipefail
cd "$(dirname "$0")/../.."

swift build -c release --product MisstypeCAPI -Xswiftc -static-stdlib \
    -Xlinker -soname=libMisstypeCAPI.so 2>&1 | grep -v "warning: the use of .mktemp." || true
test "${PIPESTATUS[0]}" -eq 0
BIN_DIR=$(swift build -c release --show-bin-path)
test -f "$BIN_DIR/libMisstypeCAPI.so"
mkdir -p build/capi
echo "$BIN_DIR" > build/capi/libdir
echo "libMisstypeCAPI.so: $BIN_DIR"
