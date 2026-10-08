#!/usr/bin/env bash
# Differential check of the Zig port against Swift MisstypeCore: decode
# bench/inputs.tsv with both on the shipping lexicon and diff every
# candidate (text, score bits, repairs, unresolved, alignment). Prints both
# latency summaries. Swift runs in the Linux dev container unless
# MISSTYPE_SWIFT_HOST=1 (e.g. on a Mac with Xcode).
#
#   python3 script/prepare_lexicon.py   # once
#   core-zig/bench/compare.sh [repeats]
set -euo pipefail
cd "$(dirname "$0")/../.."
repeats=${1:-50}
zig=$(script/zig/bootstrap.sh)
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT

resources="$out/resources"
mkdir -p "$resources"
cp .cache/mcbopomofo/lexicon.tsv .cache/mcbopomofo/toneless.tsv Resources/local_phrases.tsv "$resources/"
(cd core-zig && "$zig" build -Doptimize=ReleaseFast)
core-zig/zig-out/bin/misstype-bench "$resources" core-zig/bench/inputs.tsv "$repeats" >"$out/zig.tsv" 2>"$out/zig.log"

# Release build, as shipped; the reference goes to a file because XCTest
# interleaves its own log lines with the test's stdout.
swift_cmd="MISSTYPE_ZIG_REF=/tmp/zigref.tsv MISSTYPE_ZIG_REPEATS=$repeats swift test -c release -Xswiftc -enable-testing --filter ZigReferenceTests >&2 && cat /tmp/zigref.tsv"
if [ "${MISSTYPE_SWIFT_HOST:-0}" = 1 ]; then
    bash -c "$swift_cmd" >"$out/swift.raw" 2>"$out/swift.log"
else
    script/linux/dev.sh "$swift_cmd" >"$out/swift.raw" 2>"$out/swift.log"
fi || { tail -40 "$out/swift.log"; exit 1; }
grep -v '^swift:' "$out/swift.raw" >"$out/swift.tsv"

grep '^swift:' "$out/swift.raw"
cat "$out/zig.log"
if diff -u "$out/swift.tsv" "$out/zig.tsv" >"$out/diff"; then
    echo "MATCH: $(wc -l <"$out/zig.tsv") candidates identical"
else
    head -40 "$out/diff"
    echo "MISMATCH" >&2
    exit 1
fi
