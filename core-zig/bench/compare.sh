#!/usr/bin/env bash
# Exact-decoder gate: decode bench/inputs.tsv on the shipping lexicon and diff
# every candidate (text, score bits, repairs, unresolved, alignment) against
# tests/golden/decode.tsv, the frozen output of the retired Swift reference.
# Prints the Zig latency summary.
#
#   python3 script/prepare_lexicon.py   # once
#   core-zig/bench/compare.sh [repeats]
#   core-zig/bench/compare.sh --update  # after an INTENDED behavior change:
#                                       # rewrites the golden file; review the diff
set -euo pipefail
cd "$(dirname "$0")/../.."
update=0
if [ "${1:-}" = --update ]; then update=1; shift; fi
repeats=${1:-50}
zig=$(script/zig/bootstrap.sh)
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT

resources="$out/resources"
mkdir -p "$resources"
cp .cache/mcbopomofo/lexicon.tsv .cache/mcbopomofo/toneless.tsv Resources/local_phrases.tsv "$resources/"
(cd core-zig && "$zig" build -Doptimize=ReleaseFast)
core-zig/zig-out/bin/misstype-bench "$resources" core-zig/bench/inputs.tsv "$repeats" >"$out/zig.tsv" 2>"$out/zig.log"
cat "$out/zig.log"
if [ "$update" = 1 ]; then
    cp "$out/zig.tsv" tests/golden/decode.tsv
    echo "UPDATED tests/golden/decode.tsv: $(wc -l <"$out/zig.tsv") candidates"
    exit 0
fi
if diff -u tests/golden/decode.tsv "$out/zig.tsv" >"$out/diff"; then
    echo "MATCH: $(wc -l <"$out/zig.tsv") candidates identical to tests/golden/decode.tsv"
else
    head -40 "$out/diff"
    echo "MISMATCH against tests/golden/decode.tsv (--update only for an intended change)" >&2
    exit 1
fi
