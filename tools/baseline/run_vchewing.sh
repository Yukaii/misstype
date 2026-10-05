#!/usr/bin/env bash
# Runs inputs.tsv through vChewing's engine (LibVanguard) headlessly in Docker.
#   tools/baseline/run_vchewing.sh <inputs.tsv> <out.tsv> [configs]
# configs: comma list of default,furious,mixed (default: default,furious)
#
# Fetches LibVanguard and the Vanguard lexicon at the pinned commits below into
# .cache/baseline/ (never committed), builds the real factory lexicon with
# VCDataBuilder, copies vchewing/BaselineHarness.swift into the checkout's test
# target and runs only that test. Needs Docker and ~3 GB; first run is slow.
# vChewing's code is LGPL-3.0-or-later: it stays under .cache/, nothing of it is
# vendored or linked into Misstype.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
IN="$(realpath "$1")"; OUT="$(realpath -m "$2")"; CONFIGS="${3:-default,furious}"
LIB_SHA=8a3f8d87d8f2696a79e1dca356f23d8800f0c938     # vChewing-LibVanguard
LEX_SHA=d41f2fc244eadf94c37df50ef98e716fdc28146d     # vChewing-VanguardLexicon
SWIFT_IMAGE="${SWIFT_IMAGE:-swift:6.4}"
C="$ROOT/.cache/baseline"; mkdir -p "$C"

fetch() { # repo sha dir
  [ -d "$3/.git" ] || git clone -q "https://github.com/vChewing/$1.git" "$3"
  git -C "$3" fetch -q origin "$2" 2>/dev/null || git -C "$3" fetch -q --unshallow origin || true
  git -C "$3" checkout -q "$2"
}
fetch vChewing-LibVanguard "$LIB_SHA" "$C/LibVanguard"
fetch vChewing-VanguardLexicon "$LEX_SHA" "$C/VanguardLexicon"

LEXICON="$C/VanguardLexicon/Build/Release/vanguard-textmap/VanguardFactoryDict4Typing.txtMap"
if [ ! -f "$LEXICON" ]; then
  docker run --rm -v "$C/VanguardLexicon":/src -w /src "$SWIFT_IMAGE" \
    swift run -c release VCDataBuilder vanguardTextMap
fi
cp "$ROOT/tools/baseline/vchewing/BaselineHarness.swift" \
   "$C/LibVanguard/Tests/LibVanguardTests/BaselineHarness.swift"

W="$(mktemp -d)"; cp "$IN" "$W/in.tsv"; cp "$LEXICON" "$W/lexicon.txtMap"
docker run --rm -v "$C/LibVanguard":/src -v "$W":/work -w /src \
  -e VC_PROBES_IN=/work/in.tsv -e VC_PROBES_OUT=/work/out.tsv \
  -e VC_LEXICON=/work/lexicon.txtMap -e VC_CONFIGS="$CONFIGS" "$SWIFT_IMAGE" \
  swift test --filter BASELINE
python3 - "$W/out.tsv" "$OUT" <<'PY'
import sys
rows = open(sys.argv[1], encoding="utf-8").read().splitlines()
out = [rows[0].replace("config\t", "engine\t", 1)]
for r in rows[1:]:
    cfg, ident, committed, ms, _displayed = r.split("\t")
    out.append(f"vchewing-{cfg}\t{ident}\t{committed}\t{ms}")
open(sys.argv[2], "w", encoding="utf-8").write("\n".join(out) + "\n")
PY
rm -rf "$W"
