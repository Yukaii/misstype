#!/usr/bin/env bash
# Runs inputs.tsv through libchewing (新酷音) headlessly, natively (macOS/Linux).
#   tools/baseline/run_libchewing.sh <inputs.tsv> <out.tsv> [engines]
# engines: comma list of chewing,fuzzy (default: chewing,fuzzy)
#
# Fetches libchewing (Codeberg is upstream; the GitHub mirror stops at 0.12)
# and its libchewing-data submodule at the pinned commit into .cache/baseline/
# (never committed), builds the library and dictionaries with CMake (needs
# cmake, ninja, Rust), then drives it through compare.py drive-libchewing.
# libchewing is LGPL-2.1-or-later: it stays under .cache/, nothing of it is
# vendored or linked into Misstype.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
IN="$1"; OUT="$2"; ENGINES="${3:-chewing,fuzzy}"
LIB_SHA=f071d2e95c531cc39bb4325cd5a5d0e1d51daef8     # libchewing v0.13.1
C="$ROOT/.cache/baseline"; mkdir -p "$C"; SRC="$C/libchewing"

[ -d "$SRC/.git" ] || git clone -q https://codeberg.org/chewing/libchewing.git "$SRC"
git -C "$SRC" remote set-url origin https://codeberg.org/chewing/libchewing.git
git -C "$SRC" fetch -q origin "$LIB_SHA" 2>/dev/null || git -C "$SRC" fetch -q origin
git -C "$SRC" checkout -q "$LIB_SHA"
git -C "$SRC" submodule sync -q
git -C "$SRC" submodule update -q --init

BUILD="$SRC/build-$LIB_SHA"
if [ ! -f "$BUILD/data/dict/chewing/tsi.dat" ]; then
  cmake -S "$SRC" -B "$BUILD" -G Ninja -DCMAKE_BUILD_TYPE=Release \
    -DBUILD_DOC=OFF -DWITH_SQLITE3=OFF -DBUILD_TESTING=OFF >/dev/null
  cmake --build "$BUILD" >/dev/null
fi
LIB="$BUILD/libchewing.so"; [ -f "$LIB" ] || LIB="$BUILD/libchewing.dylib"

PYTHONPATH="$ROOT/src" python3 "$ROOT/tools/baseline/compare.py" drive-libchewing \
  --lib "$LIB" --data "$BUILD/data/dict/chewing:$BUILD/data/misc" \
  --engines "$ENGINES" --inputs "$IN" --out "$OUT"
