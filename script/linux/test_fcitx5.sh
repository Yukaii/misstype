#!/usr/bin/env bash
# L3 fcitx5 addon check (runs inside the container): builds libMisstypeCAPI.so and
# the addon, then runs the headless conformance tests (C1-C12, LR1-LR4) against
# the 7-line fixture lexicon. Needs no network and no display.
set -euo pipefail
cd "$(dirname "$0")/../.."

script/linux/build_capi.sh
BIN_DIR=$(cat build/capi/libdir)

cmake -S linux/fcitx5 -B build/fcitx5 \
    -DMISSTYPE_CAPI_DIR="$BIN_DIR" -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/usr
cmake --build build/fcitx5 -j"$(nproc)"

# -V shows the PASS lines; pass/fail is the test's exit code.
MISSTYPE_RESOURCES=$PWD/tests/fixtures/lexicon \
    ctest --test-dir build/fcitx5 --output-on-failure -V | grep -E "PASS |All .* passed|tests passed|tests failed"
echo "FCITX5 OK"
