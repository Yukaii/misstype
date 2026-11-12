"""Check the fixed JSONL fixture set against the Zig core.

Usage:
    python3 tools/bench.py [--manifest tests/fixtures/manifest.json]

For every fixture in the manifest: replay through the real core (key traces
through the `Session`, touch traces through the touch decoder; see
tools/replay.py), compare the committed text with the expectation, and
report CER per path. Exits non-zero on any mismatch or when the fixtures
were recorded under another touch layout than the core's, so it works as a
regression gate. Latency lives in tools/session_latency.py and
tools/mixed_latency.py (an optimized build; process start-up and lexicon
load would swamp a per-fixture timing here). Offline only.
"""

import argparse
import json
import statistics
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import misstype_dev as dev  # noqa: E402


def levenshtein(a: str, b: str) -> int:
    """Character edit distance; pure stdlib for CER computation."""
    if a == b:
        return 0
    previous = list(range(len(b) + 1))
    for i, ca in enumerate(a, start=1):
        current = [i]
        for j, cb in enumerate(b, start=1):
            current.append(min(previous[j] + 1, current[j - 1] + 1,
                               previous[j - 1] + (ca != cb)))
        previous = current
    return previous[-1]


def cer(expected: str, got: str) -> float:
    """Character error rate against the expected text."""
    if not expected:
        return 0.0 if not got else 1.0
    return levenshtein(expected, got) / len(expected)


def group_of(filename: str) -> str:
    """Split fixtures into the M1 keyboard path and the M2 touch path."""
    if filename.startswith("keyboard-"):
        return "keyboard"
    if filename.startswith("touch-"):
        return "touch"
    return "other"


def bench_fixture(path: Path, expected: str) -> dict:
    events = dev.load_trace(path)
    got = dev.replay_trace(events)
    return {
        "fixture": path.name,
        "group": group_of(path.name),
        "expected": expected,
        "got": got,
        "match": got == expected,
        "cer": cer(expected, got),
    }


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Check misstype fixtures against the Zig core")
    parser.add_argument("--manifest", default="tests/fixtures/manifest.json")
    args = parser.parse_args(argv)

    manifest_path = dev.ROOT / args.manifest
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    fixture_dir = manifest_path.parent

    failures: list[str] = []
    layout, _ = dev.touch_layout()
    if manifest.get("layout_version") != layout:
        failures.append(
            f"layout drift: fixtures recorded under {manifest.get('layout_version')!r} "
            f"but the core is {layout!r}; regenerate fixtures before trusting replay")

    rows = [bench_fixture(fixture_dir / name, expected)
            for name, expected in sorted(manifest["expected_text"].items())]

    print(f"{'fixture':36} {'match':5} {'cer':5} text")
    for row in rows:
        mark = "ok" if row["match"] else "FAIL"
        print(f"{row['fixture']:36} {mark:5} {row['cer']:.3f} {row['got']}")
        if not row["match"]:
            failures.append(f"{row['fixture']}: got {row['got']!r}, want {row['expected']!r}")

    print("---")
    for group in ("keyboard", "touch", "other"):
        grouped = [row for row in rows if row["group"] == group]
        if grouped:
            matched = sum(row["match"] for row in grouped)
            mean_cer = statistics.fmean(row["cer"] for row in grouped)
            print(f"{group:8} match {matched}/{len(grouped)}  mean CER {mean_cer:.3f}")

    for failure in failures:
        print(f"FAILURE: {failure}", file=sys.stderr)
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
