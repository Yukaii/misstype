#!/usr/bin/env bash
# L2 C ABI smoke test (runs inside the container, from /w)
set -euo pipefail

# Build the CAPI library
swift build -c release --product MistypeCAPI -Xswiftc -static-stdlib -Xlinker -soname=libMistypeCAPI.so 2>&1 > /dev/null

# Find the built library
BIN_DIR=$(find .build -name "libMistypeCAPI.so" -type f | head -1 | xargs dirname)
echo "Library at: $BIN_DIR"

# Build smoke test
mkdir -p build/capi
cc -std=c11 -Wall -Wextra -Werror -ISources/CMistype/include tests/capi/smoke.c -L"$BIN_DIR" -lMistypeCAPI -Wl,-rpath,"$BIN_DIR" -o build/capi/smoke 2>&1

# Run conformance scenarios
build/capi/smoke tests/fixtures/lexicon | diff -u tests/capi/expected.txt -

# Symbol parity check
HEADER_SYMBOLS=$(grep -E '^\w+\s+mistype_[a-z_]+\(|^mistype_[a-z_]+\(|^\w+\s+\*mistype_[a-z_]+\(' Sources/CMistype/include/mistype.h | sed -E 's/.*\b(mistype_[a-z_]+)\s*\(.*/\1/' | sort -u)
SO_SYMBOLS=$(nm -D --defined-only "$BIN_DIR/libMistypeCAPI.so" | grep ' T mistype_' | awk '{print $3}' | sort -u)
echo "HDR=$HEADER_SYMBOLS"
echo "SO=$SO_SYMBOLS"
if [ "$HEADER_SYMBOLS" != "$SO_SYMBOLS" ]; then
    echo "Symbol mismatch!"
    exit 1
fi

# C++ compilation check
g++ -std=c++17 -fsyntax-only -x c++ Sources/CMistype/include/mistype.h 2>&1

echo "CAPI OK"