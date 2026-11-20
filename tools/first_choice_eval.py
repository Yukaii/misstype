"""Word-level first-choice quality on clean input, and reranker headroom.

Question: with no typos at all, how often is the decoder's first choice the
intended text, and when it is not, is the intended sentence already in the
decoder's N-best list? The first number is the homophone / word-choice
quality on its own (typo repair is not exercised); the gap between it and
the N-best oracle is the most any reranker over our candidates can recover
without changing candidate generation.

Each sentence is typed cleanly, toned (every tone key) and toneless (no tone
keys), through `misstype-dev --decode`; readings come from the pinned
dictionary (`cursor_replay.readings_for`), not from human typing, so
polyphones may be read the dictionary's way. Metrics per set and mode:

  sent%    top-1 equals the sentence
  char%    1 - CER of top-1
  word%    dictionary words of the sentence (fewest-words segmentation)
           whose characters top-1 reproduces in place: the first-choice
           rate per word, comparable to per-target first-choice metrics
  @8 / @N  sentence appears in the first 8 / all returned candidates
           (the decoder returns at most 16)

Sets:
  corpus      tools/eval/typing_corpus.tsv (synthetic, hand-written; dev and
              holdout are worn by repeated tuning)
  cv-legacy   the first 2,000 unique readable pure-Han 4-16 character Common
              Voice zh-TW sentences by ID: the prefix reserve_eval.py excludes
              from external_v1 because earlier evaluations already used it
  --sentences FILE  any TSV of `text[<TAB>reading]` (kept out of the repo
              when it is private)

The reserved external_v1 set is deliberately not a choice here: read
docs/offline-evaluation.md before spending it.

Usage:
  (cd core-zig && zig build -Doptimize=ReleaseFast)
  python3 tools/first_choice_eval.py [--sets corpus,cv-legacy] [--failures 10]
  python3 tools/first_choice_eval.py --save .cache/first-choice/<name>.json
  python3 tools/first_choice_eval.py --baseline .cache/first-choice/<name>.json

Offline and deterministic; nothing is written unless --save is given.
"""

import argparse
import json
import subprocess
import sys
import time
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from cursor_replay import (APP_BIN, TONE_TO_KEY, ZHUYIN_TO_KEY,  # noqa: E402
                           load_reverse_lexicon, readings_for, split_tone)

ROOT = Path(__file__).resolve().parent.parent
CORPUS = ROOT / "tools/eval/typing_corpus.tsv"
CV = Path.home() / ".cache/misstype/cv/validated_sentences.tsv"
LEGACY_PREFIX = 2000


def keys_for(reading: str, toned: bool) -> str:
    out = []
    for syllable in reading.split():
        base, tone = split_tone(syllable)
        out.extend(ZHUYIN_TO_KEY[s] for s in base)
        if toned:
            out.append(TONE_TO_KEY[tone])
    return "".join(out)


def words_of(sentence: str, reverse: dict) -> list[tuple[int, int]]:
    """Fewest-words dictionary segmentation, the one readings_for uses."""
    inf = (float("inf"), 0.0)
    cost = [(0, 0.0)] + [inf] * len(sentence)
    back = [0] * (len(sentence) + 1)
    for end in range(1, len(sentence) + 1):
        for start in range(max(0, end - 8), end):
            word = sentence[start:end]
            if word in reverse and cost[start] != inf:
                candidate = (cost[start][0] + 1, cost[start][1] - reverse[word][1])
                if candidate < cost[end]:
                    cost[end], back[end] = candidate, start
    spans, end = [], len(sentence)
    while end > 0:
        spans.append((back[end], end))
        end = back[end]
    return spans[::-1]


def cer(expected: str, got: str) -> float:
    previous = list(range(len(got) + 1))
    for i, a in enumerate(expected, 1):
        current = [i]
        for j, b in enumerate(got, 1):
            current.append(min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (a != b)))
        previous = current
    return previous[-1] / max(len(expected), 1)


def load_corpus() -> list[tuple[str, str, str]]:
    """(group, text, reading); `auto` rows split like typing_eval (md5)."""
    import typing_eval
    reverse = load_reverse_lexicon()
    rows = []
    for set_name, category, text, reading in typing_eval.load_corpus():
        if set_name.startswith("mixed") or not all("一" <= c <= "鿿" for c in text):
            continue  # word choice only: no English, digits or punctuation
        try:
            rows.append((f"corpus:{set_name}", text, reading or readings_for(text, reverse)))
        except ValueError:
            continue
    return rows


def load_cv_legacy(reverse: dict) -> list[tuple[str, str, str]]:
    rows = []
    for line in CV.read_text(encoding="utf-8").splitlines()[1:]:
        fields = line.split("\t")
        if len(fields) < 2:
            continue
        text = fields[1].strip()
        if not 4 <= len(text) <= 16 or not all("一" <= c <= "鿿" for c in text):
            continue
        try:
            rows.append((fields[0], text, readings_for(text, reverse)))
        except ValueError:
            continue
    unique = {}
    for source_id, text, reading in sorted(rows):
        unique.setdefault(text, (source_id, text, reading))
    return [("cv-legacy", text, reading) for _, text, reading in sorted(unique.values())[:LEGACY_PREFIX]]


def load_file(path: Path, reverse: dict) -> list[tuple[str, str, str]]:
    rows = []
    for line in path.read_text(encoding="utf-8").splitlines():
        if not line.strip() or line.startswith("#"):
            continue
        fields = line.split("\t")
        text = fields[0].strip()
        try:
            reading = fields[1].strip() if len(fields) > 1 and fields[1].strip() else readings_for(text, reverse)
        except ValueError:
            continue
        rows.append((f"file:{path.stem}", text, reading))
    return rows


def decode(keys: str) -> tuple[list[str], float]:
    out = subprocess.run([str(APP_BIN), "--decode", keys], capture_output=True, text=True, check=True).stdout
    lines = out.splitlines()
    ms = float(lines[0].rsplit("decode_ms=", 1)[1]) if lines and "decode_ms=" in lines[0] else 0.0
    return [line.split("\t", 1)[0] for line in lines[1:] if line], ms


def evaluate(rows, reverse, jobs: int) -> list[dict]:
    work = [(group, text, reading, toned) for group, text, reading in rows for toned in (True, False)]

    def one(item):
        group, text, reading, toned = item
        candidates, ms = decode(keys_for(reading, toned))
        top = candidates[0] if candidates else ""
        spans = words_of(text, reverse)
        same = len(top) == len(text)
        words_ok = sum(1 for s, e in spans if same and top[s:e] == text[s:e])
        return {"group": group, "mode": "toned" if toned else "toneless", "text": text,
                "reading": reading, "top": top, "words": len(spans), "words_ok": words_ok,
                "cer": cer(text, top), "rank": candidates.index(text) + 1 if text in candidates else 0,
                "n_cands": len(candidates), "ms": ms}

    with ThreadPoolExecutor(max_workers=jobs) as pool:
        return list(pool.map(one, work))


def summarize(results: list[dict]) -> dict:
    groups: dict[str, list[dict]] = {}
    for r in results:
        groups.setdefault(f"{r['group']} | {r['mode']}", []).append(r)
        groups.setdefault(f"ALL | {r['mode']}", []).append(r)
    summary = {}
    for key, rs in sorted(groups.items()):
        n = len(rs)
        ms = sorted(r["ms"] for r in rs)
        summary[key] = {
            "n": n,
            "sent_pct": round(100 * sum(r["rank"] == 1 for r in rs) / n, 1),
            "char_pct": round(100 * (1 - sum(r["cer"] for r in rs) / n), 1),
            "word_pct": round(100 * sum(r["words_ok"] for r in rs) / max(sum(r["words"] for r in rs), 1), 1),
            "at8_pct": round(100 * sum(0 < r["rank"] <= 8 for r in rs) / n, 1),
            "atN_pct": round(100 * sum(r["rank"] > 0 for r in rs) / n, 1),
            "ms_p50": round(ms[n // 2], 2),
            "ms_p95": round(ms[min(n - 1, int(n * 0.95))], 2),
        }
    return summary


COLUMNS = ["n", "sent_pct", "char_pct", "word_pct", "at8_pct", "atN_pct", "ms_p50", "ms_p95"]


def print_table(summary: dict, baseline: dict | None) -> None:
    print(f"{'group | mode':34s}" + "".join(f"{c:>12s}" for c in COLUMNS))
    for key, row in summary.items():
        cells = []
        for c in COLUMNS:
            value = row[c]
            old = (baseline or {}).get(key, {}).get(c)
            if old is not None and c.endswith("_pct") and abs(value - old) >= 0.05:
                cells.append(f"{value}({value - old:+.1f})")
            else:
                cells.append(str(value))
        print(f"{key:34s}" + "".join(f"{v:>12s}" for v in cells))


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--sets", default="corpus,cv-legacy", help="comma list of corpus, cv-legacy")
    parser.add_argument("--sentences", type=Path, action="append", default=[], help="extra TSV text[<TAB>reading]")
    parser.add_argument("--jobs", type=int, default=8)
    parser.add_argument("--failures", type=int, default=0, help="print N misses per mode")
    parser.add_argument("--save", type=Path)
    parser.add_argument("--baseline", type=Path)
    args = parser.parse_args()
    if not APP_BIN.exists():
        parser.error(f"{APP_BIN} missing: (cd core-zig && zig build -Doptimize=ReleaseFast)")
    reverse = load_reverse_lexicon()
    rows = []
    for name in filter(None, args.sets.split(",")):
        if name == "corpus":
            rows += load_corpus()
        elif name == "cv-legacy":
            if not CV.exists():
                print(f"skip cv-legacy: {CV} missing (see tools/bigram_eval.py)", file=sys.stderr)
                continue
            rows += load_cv_legacy(reverse)
        else:
            parser.error(f"unknown set {name!r}")
    for path in args.sentences:
        rows += load_file(path, reverse)
    started = time.time()
    results = evaluate(rows, reverse, args.jobs)
    summary = summarize(results)
    baseline = json.loads(args.baseline.read_text())["summary"] if args.baseline else None
    print_table(summary, baseline)
    build = subprocess.run([str(APP_BIN), "--build-mode"], capture_output=True, text=True).stdout.strip()
    commit = subprocess.run(["git", "rev-parse", "--short", "HEAD"], capture_output=True, text=True, cwd=ROOT).stdout.strip()
    print(f"{len(results)} decodes, {time.time() - started:.1f}s, offline, {build}, commit {commit}")
    if args.failures:
        for mode in ("toned", "toneless"):
            misses = [r for r in results if r["mode"] == mode and r["rank"] != 1][:args.failures]
            for r in misses:
                print(f"  {mode:8s} {r['text']} -> {r['top']}  (rank {r['rank'] or '-'}/{r['n_cands']})")
    if args.save:
        args.save.parent.mkdir(parents=True, exist_ok=True)
        args.save.write_text(json.dumps({"meta": {"commit": commit, "build": build, "sets": args.sets},
                                         "summary": summary, "cases": results}, ensure_ascii=False, indent=1))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
