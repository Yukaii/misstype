#!/usr/bin/env bash
# L4 release build (runs inside the container): real lexicon, install layout.
#   script/linux/build.sh && DESTDIR=/tmp/stage cmake --install build/fcitx5
set -euo pipefail
cd "$(dirname "$0")/../.."

# Pinned public sources only; reuses .cache/.
python3 script/prepare_lexicon.py

script/linux/build_capi.sh
BIN_DIR=$(cat build/capi/libdir)

cc -std=c11 -Wall -Wextra -Werror -ISources/CMisstype/include tests/capi/smoke.c \
    -L"$BIN_DIR" -lMisstypeCAPI -Wl,-rpath,"$BIN_DIR" -o build/capi/smoke

cmake -S linux/fcitx5 -B build/fcitx5 \
    -DMISSTYPE_CAPI_DIR="$BIN_DIR" -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/usr
cmake --build build/fcitx5 -j"$(nproc)"

# The IBus engine (docs/ibus-port.md): sudo cmake --install build/ibus
cmake -S linux/ibus -B build/ibus \
    -DMISSTYPE_CAPI_DIR="$BIN_DIR" -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/usr
cmake --build build/ibus -j"$(nproc)"
