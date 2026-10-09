#!/usr/bin/env bash
# Full candidate metadata, touch hypotheses/costs and Unicode records vs the
# frozen Swift reference output (tests/golden/parity.tsv.gz).
#   core-zig/bench/parity.sh            # gate
#   core-zig/bench/parity.sh --update   # after an INTENDED behavior change
set -euo pipefail
cd "$(dirname "$0")/../.."
update=0
if [ "${1:-}" = --update ]; then update=1; fi
zig=$(script/zig/bootstrap.sh)
mkdir -p build/parity/resources
python3 tools/zig_cases.py build/parity/cases.jsonl
cp .cache/mcbopomofo/{lexicon,toneless}.tsv Resources/local_phrases.tsv build/parity/resources/
(cd core-zig && "$zig" build -Doptimize="${MISSTYPE_ZIG_OPTIMIZE:-Debug}")
core-zig/zig-out/bin/misstype-parity build/parity/resources build/parity/cases.jsonl > build/parity/zig.tsv 2> build/parity/zig.log
if [ "$update" = 1 ]; then
    gzip -9n -c build/parity/zig.tsv > tests/golden/parity.tsv.gz
    echo "UPDATED tests/golden/parity.tsv.gz: $(wc -l < build/parity/zig.tsv) records"
    exit 0
fi
if diff -u <(gzip -dc tests/golden/parity.tsv.gz) build/parity/zig.tsv > build/parity/diff.txt; then
    grep "^parity:" build/parity/zig.log || true
    python3 tools/zig_quality.py build/parity/cases.jsonl build/parity/zig.tsv
    echo "MATCH: $(wc -l < build/parity/zig.tsv) full candidate/touch/Unicode records identical to tests/golden/parity.tsv.gz"
else
    head -80 build/parity/diff.txt
    echo "MISMATCH: full diff in build/parity/diff.txt (--update only for an intended change)" >&2
    exit 1
fi
