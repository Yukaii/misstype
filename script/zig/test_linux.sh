#!/usr/bin/env bash
# Exercise the Zig .so through the shipping C ABI and unchanged fcitx5 addon.
# Run on a Linux host; build products remain local and no desktop is installed.
set -euo pipefail
cd "$(dirname "$0")/../.."
zig=$(script/zig/bootstrap.sh)
(cd core-zig && "$zig" build test && "$zig" build)
script/linux/dev.sh '
mkdir -p build/zig-capi
cp /src/core-zig/zig-out/lib/libMisstypeCAPI.so build/zig-capi/
libdir=$PWD/build/zig-capi
cc -std=c11 -Wall -Wextra -Werror -ISources/CMisstype/include tests/capi/smoke.c \
    -L"$libdir" -lMisstypeCAPI -Wl,-rpath,"$libdir" -o build/zig-capi/smoke
build/zig-capi/smoke tests/fixtures/lexicon | diff -u tests/capi/expected.txt -
header_symbols=$(grep -oE "misstype_[a-z0-9_]+\(" Sources/CMisstype/include/misstype.h | tr -d "(" | sort -u)
library_symbols=$(nm -D --defined-only "$libdir/libMisstypeCAPI.so" | awk '\''$2 == "T" && $3 ~ /^misstype_/ {print $3}'\'' | sort -u)
diff <(echo "$header_symbols") <(echo "$library_symbols")
echo "Zig C ABI smoke and exported symbols match"
cmake -S linux/fcitx5 -B build/fcitx5-zig -DMISSTYPE_CAPI_DIR="$libdir" \
    -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/usr
cmake --build build/fcitx5-zig -j"$(nproc)"
ctest --test-dir build/fcitx5-zig --output-on-failure -V
'
