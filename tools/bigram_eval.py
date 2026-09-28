"""Homophone bigram overlay: does ChiaKey's word bigram fix top-1 picks?

Hypothesis: most offline top-1 misses on everyday sentences are homophone
ties between dictionary words that a previous-word bigram can decide, so a
word-level overlay flips misses to hits without breaking hits (unlike the
falsified char-level LCCC bigram, which steamrolled word scores).

Runs the cursor_replay sentence sets (synthetic, dev + holdout, toned and
toneless) through the Swift `--decode` binary once per config and reports
top-1 hits, fixes, breaks, and expected-text rank. The overlay is a local
file passed via MISTYPE_BIGRAM; it is downloaded, never committed:

  gh api repos/chiakich/ChiaKey-Lexicon/contents/sources/<source>/bigrams.tsv \\
     -H "Accept: application/vnd.github.raw" > ~/.cache/mistype/chiakey/<source>.tsv

Usage:
  ./script/build_and_run.sh --build-only
  PYTHONPATH=src python tools/bigram_eval.py [--configs full:3,ck+bi:3] [--set all]
"""

import argparse
import json
import os
import subprocess
import sys
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from cursor_replay import APP_BIN, encode, sentence_set  # noqa: E402

CACHE = Path.home() / ".cache/mistype/chiakey"
SOURCES = {
    "full": CACHE / "chiaki-tw-homophone-bigram.tsv",    # CC BY-NC, measurement only
    "clean": CACHE / "chiaki-tw-homophone-bigram-clean.tsv",  # ODbL
}


def decode(keys: str, overlay: Path | None, weight: float,
           lexicon: Path | None = None) -> tuple[list[str], float]:
    env = dict(os.environ)
    env.pop("MISTYPE_BIGRAM", None)
    env.pop("MISTYPE_LEXICON", None)
    if lexicon is not None:
        env["MISTYPE_LEXICON"] = str(lexicon)
    if overlay is not None:
        env["MISTYPE_BIGRAM"] = str(overlay)
        env["MISTYPE_BIGRAM_WEIGHT"] = str(weight)
    proc = subprocess.run([str(APP_BIN), "--decode", keys], capture_output=True,
                          text=True, timeout=120, check=True, env=env)
    lines = proc.stdout.splitlines()
    header = dict(field.split("=", 1) for field in lines[0].split() if "=" in field)
    return [line.split("\t")[0] for line in lines[1:]], float(header["decode_ms"])


def run(cases, overlay, weight, lexicon=None):
    with ThreadPoolExecutor(max_workers=os.cpu_count() or 4) as pool:
        return list(pool.map(lambda c: decode(c[2], overlay, weight, lexicon), cases))


def config(spec: str) -> tuple[str, Path | None, Path | None, float]:
    """`full:w` / `clean:w`: ChiaKey bigram table over our lexicon.
    `ck:k` / `ck+bi:k`: ChiaKey unigram (exported at scale k, see
    chiakey_export.py), without / with its calibrated bigram bonuses."""
    source, _, value = spec.partition(":")
    number = float(value or 1)
    if source in SOURCES:
        return spec, SOURCES[source], None, number
    lexicon = CACHE / f"x{number:g}" / "lexicon.tsv"
    overlay = CACHE / "x1" / "bigrams.tsv" if source == "ck+bi" else None
    return spec, overlay, lexicon, number


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--set", default="all", choices=["dev", "holdout", "all"])
    parser.add_argument("--configs", default="full:3,ck:1,ck+bi:1,ck:3,ck+bi:3,ck:6,ck+bi:6")
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args()

    sets = ["dev", "holdout"] if args.set == "all" else [args.set]
    cases = [(name, style, encode(readings, style == "toned"), text)
             for name in sets for text, readings in sentence_set(name)
             for style in ("toned", "toneless")]
    base = run(cases, None, 0)
    report = []
    for spec in args.configs.split(","):
        name, overlay, lexicon, weight = config(spec)
        result = run(cases, overlay, weight, lexicon)
        row = {"config": name}
        for name in sets:
            idx = [i for i, c in enumerate(cases) if c[0] == name]
            hit0 = [base[i][0][:1] == [cases[i][3]] for i in idx]
            hit1 = [result[i][0][:1] == [cases[i][3]] for i in idx]
            row[name] = {
                "cases": len(idx), "base_top1": sum(hit0), "top1": sum(hit1),
                "fixed": [f"{cases[i][3]}/{cases[i][1]}: {base[i][0][0]}"
                          for i, a, b in zip(idx, hit0, hit1) if b and not a],
                "broken": [f"{cases[i][3]}/{cases[i][1]} -> {result[i][0][0]}"
                           for i, a, b in zip(idx, hit0, hit1) if a and not b],
            }
        row["decode_ms_mean"] = sum(ms for _, ms in result) / len(result)
        report.append(row)
    base_ms = sum(ms for _, ms in base) / len(base)
    if args.json:
        print(json.dumps({"base_decode_ms_mean": base_ms, "configs": report},
                         ensure_ascii=False, indent=2))
        return 0
    print(f"baseline decode_ms mean {base_ms:.1f}")
    for row in report:
        cells = "  ".join(f"{n} {row[n]['base_top1']}->{row[n]['top1']}/{row[n]['cases']}"
                          for n in sets)
        print(f"{row['config']:9} {cells}  ms {row['decode_ms_mean']:.1f}")
        for n in sets:
            for line in row[n]["fixed"]:
                print(f"    + {n} {line}")
            for line in row[n]["broken"]:
                print(f"    - {n} {line}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
