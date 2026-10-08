#!/usr/bin/env bash
# Replay scripts through Swift libMisstypeCAPI.so; run inside the Linux dev
# container (script/linux/dev.sh). Prints the transcript on stdout.
#   tests/replay/run_swift.sh <script>...
set -euo pipefail
cd "$(dirname "$0")/../.."
MISSTYPE_CORE=swift script/linux/build_capi.sh >&2
BIN_DIR=$(cat build/capi/libdir)
mkdir -p build/replay
cc -std=c11 -O1 -Wall -Wextra -Werror -ISources/CMisstype/include tests/replay/replay.c \
    -L"$BIN_DIR" -lMisstypeCAPI -Wl,-rpath,"$BIN_DIR" -o build/replay/replay-swift
res=build/replay/shipping
mkdir -p "$res"
cp .cache/mcbopomofo/lexicon.tsv .cache/mcbopomofo/toneless.tsv .cache/frequencywords/english.tsv \
    Resources/local_phrases.tsv "$res/"
# english.tsv loads on a background queue in Swift; give it time.
MISSTYPE_REPLAY_WAIT=${MISSTYPE_REPLAY_WAIT:-3} build/replay/replay-swift "$res" tests/fixtures/lexicon "$@"
