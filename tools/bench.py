"""Benchmark the fixed fixture set and compare keyboard vs touch paths.

Usage:
    PYTHONPATH=src python tools/bench.py [--repeats 101] [--manifest tests/fixtures/manifest.json]

For every fixture in the manifest: replay through the real pipeline,
check decoded text against expectation, and time normalize+decode over
N repeats (mean/p50/p95). Exits non-zero on any text mismatch or on a
layout-version drift between fixtures and code, so it works as a
regression gate. Offline only.
"""

import argparse
import json
import statistics
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from replay import load_events, run  # noqa: E402
from misstype.touch import LAYOUT_VERSION  # noqa: E402


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


def bench_fixture(path: Path, expected: str, repeats: int) -> dict:
    """Replay once for correctness, then time the pipeline for latency."""
    events = load_events(path)
    result, _ = run(events)
    latencies = []
    for _ in range(repeats):
        started = time.perf_counter_ns()
        run(events)
        latencies.append((time.perf_counter_ns() - started) / 1_000_000)
    latencies.sort()
    return {
        "fixture": path.name,
        "group": group_of(path.name),
        "expected": expected,
        "got": result.text,
        "match": result.text == expected,
        "cer": cer(expected, result.text),
        "confidence": result.confidence,
        "decoder": f"{result.decoder_id}/{result.decoder_version}",
        "mean_ms": statistics.fmean(latencies),
        "p50_ms": latencies[len(latencies) // 2],
        "p95_ms": latencies[min(len(latencies) - 1, int(len(latencies) * 0.95))],
    }


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Benchmark misstype fixtures")
    parser.add_argument("--repeats", type=int, default=101)
    parser.add_argument("--manifest", default="tests/fixtures/manifest.json")
    args = parser.parse_args(argv)

    root = Path.cwd()
    manifest_path = root / args.manifest
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    fixture_dir = manifest_path.parent

    failures: list[str] = []
    if manifest.get("layout_version") != LAYOUT_VERSION:
        failures.append(
            f"layout drift: fixtures recorded under {manifest.get('layout_version')!r} "
            f"but code is {LAYOUT_VERSION!r}; regenerate fixtures before trusting replay")

    rows = [bench_fixture(fixture_dir / name, expected, args.repeats)
            for name, expected in sorted(manifest["expected_text"].items())]

    header = f"{'fixture':36} {'match':5} {'cer':5} {'conf':5} {'mean_ms':8} {'p50_ms':7} {'p95_ms':7} text"
    print(header)
    for row in rows:
        mark = "ok" if row["match"] else "FAIL"
        print(f"{row['fixture']:36} {mark:5} {row['cer']:.3f} "
              f"{row['confidence']:.2f} {row['mean_ms']:8.4f} "
              f"{row['p50_ms']:7.4f} {row['p95_ms']:7.4f} {row['got']}")
        if not row["match"]:
            failures.append(f"{row['fixture']}: got {row['got']!r}, "
                            f"want {row['expected']!r}")

    print("---")
    for group in ("keyboard", "touch", "other"):
        grouped = [row for row in rows if row["group"] == group]
        if not grouped:
            continue
        matched = sum(row["match"] for row in grouped)
        mean_cer = statistics.fmean(row["cer"] for row in grouped)
        mean_conf = statistics.fmean(row["confidence"] for row in grouped)
        print(f"{group:8} match {matched}/{len(grouped)}  "
              f"mean CER {mean_cer:.3f}  mean confidence {mean_conf:.2f}")

    for failure in failures:
        print(f"FAILURE: {failure}", file=sys.stderr)
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
