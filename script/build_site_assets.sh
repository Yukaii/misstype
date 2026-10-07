#!/usr/bin/env bash
# Generates the files the site's live demo downloads into site/public/
# (gitignored): lexicon.tsv, toneless.tsv, english.tsv and misstype.wasm.
# Used by .github/workflows/pages.yml; also runs locally.
#
#   script/build_site_assets.sh            lexicon + English list + wasm
#   script/build_site_assets.sh --data     lexicon + English list only
#
# The wasm step needs a Swift 6.0.3 toolchain and the matching SwiftWasm SDK
# (installed here when missing). Only pinned public sources are downloaded.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/site/public"
SDK_URL="https://github.com/swiftwasm/swift/releases/download/swift-wasm-6.0.3-RELEASE/swift-wasm-6.0.3-RELEASE-wasm32-unknown-wasi.artifactbundle.zip"
SDK_SUM="31d3585b06dd92de390bacc18527801480163188cd7473f492956b5e213a8618"

mkdir -p "$OUT"
python3 "$ROOT/script/prepare_lexicon.py"
cat "$ROOT/.cache/mcbopomofo/lexicon.tsv" "$ROOT/Resources/local_phrases.tsv" > "$OUT/lexicon.tsv"
cp "$ROOT/.cache/mcbopomofo/toneless.tsv" "$ROOT/.cache/frequencywords/english.tsv" "$OUT/"

[ "${1:-}" = "--data" ] && exit 0

if ! swift sdk list 2>/dev/null | grep -q 'wasm32-unknown-wasi'; then
  swift sdk install "$SDK_URL" --checksum "$SDK_SUM"
fi

exports=()
for name in alloc free init handle_key pick_candidate commit load_english toggle_english \
            set_english reset clear_committed set_setting get_state_json; do
  exports+=(-Xlinker "--export=misstype_wasm_$name")
done

cd "$ROOT"
swift build --product MisstypeWasm --swift-sdk wasm32-unknown-wasi -c release \
  "${exports[@]}" -Xlinker --strip-all
cp .build/wasm32-unknown-wasi/release/MisstypeWasm.wasm "$OUT/misstype.wasm"
