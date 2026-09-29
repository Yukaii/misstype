#!/usr/bin/env bash
# L2 C ABI check (runs inside the container, from /w): builds libMistypeCAPI.so,
# runs tests/capi/smoke.c against expected.txt, and checks that the exported
# symbols are exactly the functions declared in mistype.h.
set -euo pipefail
cd "$(dirname "$0")/../.."

script/linux/build_capi.sh
BIN_DIR=$(cat build/capi/libdir)

mkdir -p build/capi
cc -std=c11 -Wall -Wextra -Werror -ISources/CMistype/include tests/capi/smoke.c \
    -L"$BIN_DIR" -lMistypeCAPI -Wl,-rpath,"$BIN_DIR" -o build/capi/smoke
build/capi/smoke tests/fixtures/lexicon | diff -u tests/capi/expected.txt -

HEADER_SYMBOLS=$(grep -oE '\bmistype_[a-z0-9_]+\(' Sources/CMistype/include/mistype.h | tr -d '(' | sort -u)
SO_SYMBOLS=$(nm -D --defined-only "$BIN_DIR/libMistypeCAPI.so" | awk '$2 == "T" && $3 ~ /^mistype_/ {print $3}' | sort -u)
if [ -z "$HEADER_SYMBOLS" ] || [ "$HEADER_SYMBOLS" != "$SO_SYMBOLS" ]; then
    echo "Symbol mismatch between mistype.h and libMistypeCAPI.so"
    diff <(echo "$HEADER_SYMBOLS") <(echo "$SO_SYMBOLS") || true
    exit 1
fi
echo "$(echo "$HEADER_SYMBOLS" | wc -l | tr -d ' ') exported symbols match the header"

g++ -std=c++17 -Wall -Wextra -Werror -fsyntax-only -x c++ Sources/CMistype/include/mistype.h
echo "CAPI OK"
