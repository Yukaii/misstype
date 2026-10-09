#!/usr/bin/env bash
# Generates the files the site's live demo downloads into site/public/
# (gitignored): lexicon.tsv, toneless.tsv, english.tsv and misstype.wasm.
# Used by .github/workflows/pages.yml; also runs locally.
#
#   script/build_site_assets.sh            lexicon + English list + wasm
#   script/build_site_assets.sh --data     lexicon + English list only
#
# The wasm step builds core-zig for wasm32-wasi with the pinned Zig toolchain
# (script/zig/bootstrap.sh). Only pinned public sources are downloaded.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/site/public"

mkdir -p "$OUT"
python3 "$ROOT/script/prepare_lexicon.py"
cat "$ROOT/.cache/mcbopomofo/lexicon.tsv" "$ROOT/Resources/local_phrases.tsv" > "$OUT/lexicon.tsv"
cp "$ROOT/.cache/mcbopomofo/toneless.tsv" "$ROOT/.cache/frequencywords/english.tsv" "$OUT/"

[ "${1:-}" = "--data" ] && exit 0

zig=$("$ROOT/script/zig/bootstrap.sh")
(cd "$ROOT/core-zig" && "$zig" build wasm)
cp "$ROOT/core-zig/zig-out/wasm/misstype.wasm" "$OUT/misstype.wasm"
