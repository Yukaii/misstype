#!/usr/bin/env bash
# Full candidate metadata, touch hypotheses/costs, and Unicode vs Swift.
set -euo pipefail
cd "$(dirname "$0")/../.."
zig=$(script/zig/bootstrap.sh)
mkdir -p build/parity/resources
python3 tools/zig_cases.py build/parity/cases.jsonl
cp .cache/mcbopomofo/{lexicon,toneless}.tsv Resources/local_phrases.tsv build/parity/resources/
(cd core-zig && "$zig" build -Doptimize="${MISSTYPE_ZIG_OPTIMIZE:-Debug}")
core-zig/zig-out/bin/misstype-parity build/parity/resources build/parity/cases.jsonl > build/parity/zig.tsv 2> build/parity/zig.log
script/linux/dev.sh 'mkdir -p build/parity; python3 tools/zig_cases.py build/parity/cases.jsonl; MISSTYPE_PARITY_CASES=build/parity/cases.jsonl MISSTYPE_PARITY_OUTPUT=build/parity/swift.tsv swift test -c release -Xswiftc -enable-testing --filter ZigParityTests >&2; cat build/parity/swift.tsv' > build/parity/swift.tsv 2> build/parity/swift.log || { tail -40 build/parity/swift.log; exit 1; }
if diff -u build/parity/swift.tsv build/parity/zig.tsv > build/parity/diff.txt; then
    grep "^parity:" build/parity/zig.log build/parity/swift.log
    python3 tools/zig_quality.py build/parity/cases.jsonl build/parity/zig.tsv
    echo "MATCH: $(wc -l < build/parity/zig.tsv) full candidate/touch/Unicode records"
else
    head -80 build/parity/diff.txt
    exit 1
fi
