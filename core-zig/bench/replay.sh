#!/usr/bin/env bash
# Compare every C ABI key result and view against Swift on synthetic scripts.
# Outputs stay under build/replay; Linux reference runs in the dev container.
# Usage: core-zig/bench/replay.sh [fuzz cases] [seed]
set -euo pipefail
cd "$(dirname "$0")/../.."
cases=${1:-400}
seed=${2:-1}
[[ "$cases" =~ ^[0-9]+$ && "$seed" =~ ^[0-9]+$ ]] || { echo "cases and seed must be nonnegative integers" >&2; exit 2; }
zig=$(script/zig/bootstrap.sh)
out=build/replay
mkdir -p "$out/shipping"
python3 tests/replay/make_scripts.py "$out/scripts" --fuzz-cases "$cases" --seed "$seed"
cp .cache/mcbopomofo/lexicon.tsv .cache/mcbopomofo/toneless.tsv \
    .cache/frequencywords/english.tsv Resources/local_phrases.tsv "$out/shipping/"
# Debug catches overflow and bounds errors that ReleaseFast would hide. The
# ReleaseFast CI leg already has the same optimized tests in zig-core; skipping
# them here avoids paying for a second test build before replay.
if [ "${MISSTYPE_REPLAY_SKIP_TESTS:-0}" = 1 ]; then
    (cd core-zig && ../script/ci/time.sh zig-replay-build "$zig" build -Doptimize="${MISSTYPE_ZIG_OPTIMIZE:-Debug}")
else
    (cd core-zig && ../script/ci/time.sh zig-tests "$zig" build test && \
        ../script/ci/time.sh zig-replay-build "$zig" build -Doptimize="${MISSTYPE_ZIG_OPTIMIZE:-Debug}")
fi
LD_LIBRARY_PATH="$PWD/core-zig/zig-out/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" \
    MISSTYPE_REPLAY_METRICS=1 \
    script/ci/time.sh zig-session-replay core-zig/zig-out/bin/replay "$out/shipping" tests/fixtures/lexicon \
    tests/replay/conformance.txt "$out/scripts/probes.txt" "$out/scripts/fuzz.txt" > "$out/zig.txt" 2> "$out/zig.log" \
    || { tail -40 "$out/zig.log"; exit 1; }
# dev.sh excludes build/, so generate identical scripts inside the container.
script/linux/dev.sh "python3 tests/replay/make_scripts.py build/replay/scripts --fuzz-cases '$cases' --seed '$seed' && MISSTYPE_REPLAY_METRICS=1 tests/replay/run_swift.sh tests/replay/conformance.txt build/replay/scripts/probes.txt build/replay/scripts/fuzz.txt" \
    > "$out/swift.txt" 2> "$out/swift.log" || { tail -40 "$out/swift.log"; exit 1; }
if diff -u "$out/swift.txt" "$out/zig.txt" > "$out/diff.txt"; then
    echo "MATCH: $(wc -l < "$out/zig.txt") transcript lines (fuzz cases=$cases seed=$seed)"
    grep '^replay:' "$out/zig.log" "$out/swift.log"
    grep '^timing:' "$out/zig.log" "$out/swift.log"
else
    head -80 "$out/diff.txt"
    echo "MISMATCH: full diff in $out/diff.txt" >&2
    exit 1
fi
