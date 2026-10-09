#!/usr/bin/env bash
# Replays the conformance script, the probe script and seeded fuzz scripts
# through the C ABI and diffs every key result and view against the frozen
# Swift transcripts (tests/golden/replay_<cases>_<seed>.txt.gz).
# Outputs stay under build/replay.
#   core-zig/bench/replay.sh [fuzz cases] [seed]          # gate (400 1 and 400 487 are frozen)
#   core-zig/bench/replay.sh --update [fuzz cases] [seed] # after an INTENDED behavior change
set -euo pipefail
cd "$(dirname "$0")/../.."
update=0
if [ "${1:-}" = --update ]; then update=1; shift; fi
cases=${1:-400}
seed=${2:-1}
[[ "$cases" =~ ^[0-9]+$ && "$seed" =~ ^[0-9]+$ ]] || { echo "cases and seed must be nonnegative integers" >&2; exit 2; }
golden=tests/golden/replay_${cases}_${seed}.txt.gz
[ "$update" = 1 ] || [ -f "$golden" ] || { echo "no golden transcript $golden (frozen: 400/1, 400/487; --update creates one)" >&2; exit 2; }
zig=$(script/zig/bootstrap.sh)
out=build/replay
mkdir -p "$out/shipping"
python3 tests/replay/make_scripts.py "$out/scripts" --fuzz-cases "$cases" --seed "$seed"
cp .cache/mcbopomofo/lexicon.tsv .cache/mcbopomofo/toneless.tsv \
    .cache/frequencywords/english.tsv Resources/local_phrases.tsv "$out/shipping/"
# Debug catches overflow and bounds errors that ReleaseFast would hide. The
# ReleaseFast CI leg already has the same optimized tests in zig-core; skipping
# them here avoids paying for a second test build before replay.
if [ "${MISSTYPE_REPLAY_SKIP_BUILD:-0}" = 1 ]; then
    test -x core-zig/zig-out/bin/replay || {
        echo "replay: cannot reuse missing core-zig/zig-out/bin/replay" >&2
        exit 2
    }
    echo "replay: reusing existing zig replay build" >&2
elif [ "${MISSTYPE_REPLAY_SKIP_TESTS:-0}" = 1 ]; then
    (cd core-zig && ../script/ci/time.sh zig-replay-build "$zig" build -Doptimize="${MISSTYPE_ZIG_OPTIMIZE:-Debug}")
else
    (cd core-zig && ../script/ci/time.sh zig-tests "$zig" build test && \
        ../script/ci/time.sh zig-replay-build "$zig" build -Doptimize="${MISSTYPE_ZIG_OPTIMIZE:-Debug}")
fi
LD_LIBRARY_PATH="$PWD/core-zig/zig-out/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" \
DYLD_LIBRARY_PATH="$PWD/core-zig/zig-out/lib${DYLD_LIBRARY_PATH:+:$DYLD_LIBRARY_PATH}" \
    MISSTYPE_REPLAY_METRICS=1 \
    script/ci/time.sh zig-session-replay core-zig/zig-out/bin/replay "$out/shipping" tests/fixtures/lexicon \
    tests/replay/conformance.txt "$out/scripts/probes.txt" "$out/scripts/fuzz.txt" > "$out/zig.txt" 2> "$out/zig.log" \
    || { tail -40 "$out/zig.log"; exit 1; }
if [ "$update" = 1 ]; then
    gzip -9n -c "$out/zig.txt" > "$golden"
    echo "UPDATED $golden: $(wc -l < "$out/zig.txt") transcript lines"
    exit 0
fi
if diff -u <(gzip -dc "$golden") "$out/zig.txt" > "$out/diff.txt"; then
    echo "MATCH: $(wc -l < "$out/zig.txt") transcript lines identical to $golden (fuzz cases=$cases seed=$seed)"
    grep '^replay:' "$out/zig.log" || true
    grep '^timing:' "$out/zig.log" || true
else
    head -80 "$out/diff.txt"
    echo "MISMATCH: full diff in $out/diff.txt (--update only for an intended change)" >&2
    exit 1
fi
