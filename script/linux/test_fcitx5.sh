#!/usr/bin/env bash
# L3 fcitx5 addon headless test (runs inside the container, from /w)
set -euo pipefail

# Prepare lexicon (downloads pinned sources, uses .cache/)
python3 script/prepare_lexicon.py

# Build the CAPI library first
swift build -c release --product MistypeCAPI -Xswiftc -static-stdlib -Xlinker -soname=libMistypeCAPI.so 2>&1 > /dev/null

# Find the built library
BIN_DIR=$(find .build -name "libMistypeCAPI.so" -type f | head -1 | xargs dirname)
echo "Library at: $BIN_DIR"

# Configure and build fcitx5 addon
mkdir -p build/fcitx5
cmake -S linux/fcitx5 -B build/fcitx5 \
    -DMISTYPE_CAPI_DIR="$BIN_DIR" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX=/usr \
    2>&1

cmake --build build/fcitx5 -- -j$(nproc) 2>&1

# Run headless tests
MISTYPE_RESOURCES=$PWD/tests/fixtures/lexicon ctest --test-dir build/fcitx5 --output-on-failure 2>&1

echo "FCITX5 OK"