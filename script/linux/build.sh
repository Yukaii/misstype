#!/usr/bin/env bash
# L4 release build and install layout (runs inside the container, from /w)
set -euo pipefail

# Prepare lexicon (downloads pinned sources, uses .cache/)
python3 script/prepare_lexicon.py

# Build CAPI library
swift build -c release --product MistypeCAPI -Xswiftc -static-stdlib -Xlinker -soname=libMistypeCAPI.so

# Find the built library
BIN_DIR=$(find .build -name "libMistypeCAPI.so" -type f | head -1 | xargs dirname)
echo "Library at: $BIN_DIR"

# Build smoke test
mkdir -p build/capi
cc -std=c11 -Wall -Wextra -Werror -ISources/CMistype/include tests/capi/smoke.c -L"$BIN_DIR" -lMistypeCAPI -Wl,-rpath,"$BIN_DIR" -o build/capi/smoke

# Configure and build fcitx5 addon
mkdir -p build/fcitx5
cmake -S linux/fcitx5 -B build/fcitx5 \
    -DMISTYPE_CAPI_DIR="$BIN_DIR" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX=/usr \
    2>&1

cmake --build build/fcitx5 -- -j$(nproc) 2>&1

# Install to DESTDIR
DESTDIR="${DESTDIR:-/tmp/stage}"
DESTDIR="$DESTDIR" cmake --install build/fcitx5 --prefix /usr 2>&1

# Print installed files
find "$DESTDIR" -type f | sed -E "s#/lib/[^/]+-linux-gnu/#/lib/<multiarch>/#" | sort