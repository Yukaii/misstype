"""Homophone word-bigram rerank (experiment, tools-only, nothing ships).

Hypothesis: when the top candidates differ only by homophones (same reading,
different characters: 自/字, 在/再), a previous-word -> word association from
a large Traditional Chinese corpus can pick the right one without touching
syllable segmentation or repair, and without the colloquial-bias damage of
the falsified char-level LCCC bigram (docs/project-outline.md).

Differences from the falsified runs:
  * counts are WORD pairs from a lexicon-DP segmentation, so 各自|的 is not
    counted as 自|的;
  * a pair only speaks when it was seen >= --min-count times; unseen pairs
    contribute exactly 0 (no floors deciding);
  * only candidates in the top-1's homophone class (same length, differing
    characters share a reading) are reordered, by a capped PMI delta.

Falsified if: on held-out sentences fixes <= breaks at every weight, or any
weight that fixes cases also breaks toneless/controls.

  # build: one HPLT zho_Hant parquet shard (CC0 dataset, local cache only)
  /tmp/venv_pq/bin/python -I tools/homophone_bigram.py build SHARD.parquet \\
      --resources site/public --out ~/.cache/misstype/hplt/pairs.tsv
  # eval: dev + holdout synthetic sentences, toned and toneless
  PYTHONPATH=src python tools/homophone_bigram.py eval \\
      --pairs ~/.cache/misstype/hplt/pairs.tsv --resources site/public
"""

import argparse
import itertools
import math
import os
import re
import subprocess
import sys
from collections import Counter
from concurrent.futures import ThreadPoolExecutor
from multiprocessing import Pool
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
HAN = re.compile(r"[一-鿿]+")
UNKNOWN = -18.0
WORD_PENALTY = 0.5
MAX_WORD = 8


class Lex:
    def __init__(self, path: Path):
        self.score: dict[str, float] = {}
        self.readings: dict[str, set[str]] = {}
        by_reading: dict[str, set[str]] = {}
        for line in path.read_text(encoding="utf-8").splitlines():
            f = line.split("\t")
            if len(f) != 3 or not f[1] or not HAN.fullmatch(f[1]):
                continue
            try:
                s = float(f[2])
            except ValueError:
                continue
            reading, word = f[0], f[1]
            if len(reading.split("-")) != len(word):
                continue
            if word not in self.score or s > self.score[word]:
                self.score[word] = s
            self.readings.setdefault(word, set()).add(reading)
            by_reading.setdefault(reading, set()).add(word)
        self.ambiguous = {w for w, rs in self.readings.items()
                          if any(len(by_reading[r]) > 1 for r in rs)}
        # the homophone group's default: the best-scoring word sharing a reading
        self.default: dict[str, str] = {}
        for w, rs in self.readings.items():
            alts = {a for r in rs for a in by_reading[r]}
            top = max(alts, key=lambda a: (self.score[a], a))
            if top != w:
                self.default[w] = top

    def segment(self, text: str) -> list[str]:
        n = len(text)
        best = [0.0] + [-1e18] * n
        back = [0] * (n + 1)
        for end in range(1, n + 1):
            for start in range(max(0, end - MAX_WORD), end):
                word = text[start:end]
                s = self.score.get(word)
                if s is None:
                    if end - start != 1:
                        continue
                    s = UNKNOWN
                c = best[start] + s - WORD_PENALTY
                if c > best[end]:
                    best[end], back[end] = c, start
        out, end = [], n
        while end > 0:
            out.append(text[back[end]:end])
            end = back[end]
        return out[::-1]


_LEX: Lex | None = None
_PATH = ""


def _count_group(args):
    shard, rg = args
    import pyarrow.parquet as pq
    uni, pair = Counter(), Counter()
    texts = pq.ParquetFile(shard).read_row_group(rg, columns=["text"]).column("text").to_pylist()
    for doc in texts:
        for run in HAN.findall(doc):
            if len(run) < 2:
                continue
            words = _LEX.segment(run)
            uni.update(words)
            for a, b in zip(words, words[1:]):
                if b in _LEX.ambiguous:
                    pair[(a, b)] += 1
    return uni, pair


def _init(path):
    global _LEX
    _LEX = Lex(Path(path))


def build(args):
    import pyarrow.parquet as pq
    todo = []
    for shard in args.shards:
        groups = pq.ParquetFile(shard).metadata.num_row_groups
        todo += [(shard, rg) for rg in range(min(groups, args.groups))]
    uni, pair = Counter(), Counter()
    with Pool(args.jobs, initializer=_init, initargs=(str(Path(args.resources) / "lexicon.tsv"),)) as pool:
        for i, (u, p) in enumerate(pool.imap_unordered(_count_group, todo), 1):
            uni.update(u)
            pair.update(p)
            print(f"row group {i}/{len(todo)}  pairs {len(pair):,}", file=sys.stderr, flush=True)
    total = sum(uni.values())
    keep = {k: v for k, v in pair.items() if v >= args.keep}
    words = {w for k in keep for w in k}
    out = Path(args.out).expanduser()
    out.parent.mkdir(parents=True, exist_ok=True)
    with out.open("w", encoding="utf-8") as fh:
        fh.write(f"#total\t{total}\n")
        for w in sorted(words):
            fh.write(f"#u\t{w}\t{uni[w]}\n")
        for (a, b), c in sorted(keep.items(), key=lambda kv: -kv[1]):
            fh.write(f"{a}\t{b}\t{c}\n")
    print(f"tokens {total:,}  pairs kept {len(keep):,}  words {len(words):,}  -> {out}")


def fnv_key(previous: str, current: str) -> int:
    h = 0xcbf29ce484222325
    for b in previous.encode():
        h = ((h ^ b) * 0x100000001b3) & 0xFFFFFFFFFFFFFFFF
    h = ((h ^ 0xFF) * 0x100000001b3) & 0xFFFFFFFFFFFFFFFF
    for b in current.encode():
        h = ((h ^ b) * 0x100000001b3) & 0xFFFFFFFFFFFFFFFF
    return h >> 24


def export(args):
    """Write the table `core-zig/src/homophone.zig` reads."""
    import struct
    bg = Bigram(Path(args.pairs).expanduser(), args.min_count, args.cap, args.smooth)
    kept = bg.prune(args.top_pairs, rank=args.rank)
    entries = {}
    for (a, b), v in bg.value.items():
        q = int(round(v * 4))
        if q:
            entries[fnv_key(a, b)] = q & 0xFF
    blob = b"MSHB" + struct.pack("<III", 1, len(entries), 4) + b"".join(
        struct.pack("<Q", (key << 8) | entries[key]) for key in sorted(entries))
    out = Path(args.out).expanduser()
    out.write_bytes(blob)
    print(f"pairs {kept:,} -> {len(entries):,} entries, {len(blob):,} bytes -> {out}")


class Bigram:
    def __init__(self, path: Path, min_count: int, cap: float, smooth: float = 0.0,
                 default: dict[str, str] | None = None, signed: bool = False):
        self.default, self.signed = default, signed
        self.uni: dict[str, int] = {}
        self.pair: dict[tuple[str, str], int] = {}
        self.total = 1
        for line in path.read_text(encoding="utf-8").splitlines():
            f = line.split("\t")
            if f[0] == "#total":
                self.total = int(f[1])
            elif f[0] == "#u":
                self.uni[f[1]] = int(f[2])
            elif len(f) == 3:
                self.pair[(f[0], f[1])] = int(f[2])
        self.min_count, self.cap, self.smooth = min_count, cap, smooth
        self.value: dict[tuple[str, str], float] | None = None

    def prune(self, keep: int, step: float = 0.25, rank: str = "pmi") -> int:
        """Keep the `keep` pairs with the largest |capped PMI| and quantize
        them to `step`; returns how many survive (non-zero after rounding)."""
        scored = []
        for (a, b), c in self.pair.items():
            if c < self.min_count:
                continue
            v = max(-self.cap, min(self.cap, self.pmi(a, b, c)))
            weight = {"pmi": abs(v), "count": c, "impact": c * abs(v), "sqrt": math.sqrt(c) * abs(v)}[rank]
            scored.append((weight, a, b, v))
        scored.sort(reverse=True)
        self.value = {}
        for _, a, b, v in scored[:keep]:
            q = round(v / step) * step
            if q:
                self.value[(a, b)] = q
        return len(self.value)

    def pmi(self, a: str, b: str, c: int) -> float:
        ua, ub = self.uni.get(a, 1), self.uni.get(b, 1)
        pb = (ub + 1) / self.total
        # add-m on observed and expected counts: a handful of sightings
        # of a rare word cannot produce a huge association
        return math.log((c + self.smooth) / (ua * pb + self.smooth))

    def bonus(self, words: list[str]) -> float:
        s = 0.0
        for a, b in zip(words, words[1:]):
            if self.value is not None:
                s += self.value.get((a, b), 0.0)
                continue
            c = self.pair.get((a, b), 0)
            if c < self.min_count:
                continue
            if self.default is None:
                s += max(-self.cap, min(self.cap, self.pmi(a, b, c)))
                continue
            # promotion only: how much more `b` follows `a` than the group
            # default does; the default itself (and unseen pairs) get 0
            d = self.default.get(b)
            if d is None:
                continue
            delta = self.pmi(a, b, c) - self.pmi(a, d, self.pair.get((a, d), 0))
            if delta > 0 or self.signed:
                s += max(-self.cap, min(self.cap, delta))
        return s


def same_class(top: str, cand: str, lex: Lex) -> bool:
    if len(top) != len(cand):
        return False
    for a, b in zip(top, cand):
        if a == b:
            continue
        ra = {r for r in lex.readings.get(a, ())}
        rb = {r for r in lex.readings.get(b, ())}
        if not ra & rb:
            return False
    return True


def decode(binary, resources, keys, env=None):
    proc = subprocess.run([binary, "--resources", str(resources), "--decode", keys],
                          capture_output=True, text=True, timeout=120, check=True,
                          env=None if env is None else {**os.environ, **env})
    rows = []
    for line in proc.stdout.splitlines()[1:]:
        f = line.split("\t")
        if len(f) >= 2:
            rows.append((f[0], float(f[1])))
    return rows


def rerank(rows, lex: Lex, bg: Bigram, weight: float):
    if not rows:
        return rows
    top = rows[0][0]
    base = bg.bonus(lex.segment(top))
    adj = []
    for text, score in rows:
        if text != top and same_class(top, text, lex):
            delta = bg.bonus(lex.segment(text)) - base
            score = score + weight * delta
        adj.append((text, score))
    return sorted(adj, key=lambda r: -r[1])


def evaluate(args):
    sys.path.insert(0, str(ROOT / "tools"))
    sys.path.insert(0, str(ROOT / "src"))
    import cursor_replay as cr
    resources = Path(args.resources)
    cr.LEXICON = resources / "lexicon.tsv"
    reverse = cr.load_reverse_lexicon(resources / "lexicon.tsv")
    lex = Lex(resources / "lexicon.tsv")
    cases = []
    for name in ("dev", "holdout"):
        src = cr.SEED + [(t, cr.readings_for(t, reverse)) for t in cr.DEV_EXTRA] if name == "dev" \
            else [(t, cr.readings_for(t, reverse)) for t in cr.HOLDOUT]
        for text, readings in src:
            for style in ("toned", "toneless"):
                cases.append((name, style, cr.encode(readings, style == "toned"), text))
    if args.cv_count:
        # Common Voice 25 zh-TW validated sentences (CC0, local cache only):
        # same selection as bigram_eval.cv_set, first N by sentence_id.
        cv = Path.home() / ".cache/misstype/cv/validated_sentences.tsv"
        rows = []
        for line in cv.read_text(encoding="utf-8").splitlines()[1:]:
            f = line.split("\t")
            if len(f) >= 2 and 4 <= len(f[1].strip()) <= 16 and HAN.fullmatch(f[1].strip()):
                rows.append((f[0], f[1].strip()))
        taken = 0
        for _, text in sorted(rows):
            try:
                readings = cr.readings_for(text, reverse)
            except ValueError:
                continue
            for style in ("toned", "toneless"):
                cases.append(("cv", style, cr.encode(readings, style == "toned"), text))
            taken += 1
            if taken >= args.cv_count:
                break
    if args.shard:
        # contamination guard: drop sentences that occur verbatim in the
        # corpus the counts came from (the table would then be "memorized")
        import pyarrow.parquet as pq
        texts = {c[3] for c in cases}
        found = set()
        for shard in args.shard:
            pf = pq.ParquetFile(shard)
            for rg in range(pf.metadata.num_row_groups):
                for doc in pf.read_row_group(rg, columns=["text"]).column("text").to_pylist():
                    found.update(t for t in texts if t in doc)
        print(f"verbatim in shard: {len(found)} of {len(texts)} sentences; dropped")
        cases = [c for c in cases if c[3] not in found]
    for extra in args.extra:
        text, _, keys = extra.partition("=")
        cases.append(("extra", "toned", keys, text))
    binary = str(cr.APP_BIN)
    with ThreadPoolExecutor(max_workers=os.cpu_count() or 4) as pool:
        decoded = list(pool.map(lambda c: decode(binary, resources, c[2]), cases))
    base_hit = [bool(r) and r[0][0] == c[3] for r, c in zip(decoded, cases)]
    print(f"cases {len(cases)}  baseline top-1 {sum(base_hit)}")
    if args.native:
        # the Zig core's own rerank over resources/homophone.bin
        base_n = list(ThreadPoolExecutor(os.cpu_count() or 4).map(
            lambda c: decode(binary, resources, c[2], {"MISSTYPE_NO_HOMOPHONE": "1"}), cases))
        hit0 = [bool(r) and r[0][0] == c[3] for r, c in zip(base_n, cases)]
        print(f"native baseline top-1 {sum(hit0)}/{len(cases)}")
        for weight in args.weights:
            res = list(ThreadPoolExecutor(os.cpu_count() or 4).map(
                lambda c: decode(binary, resources, c[2], {"MISSTYPE_HOMOPHONE_WEIGHT": str(weight)}), cases))
            hit1 = [bool(r) and r[0][0] == c[3] for r, c in zip(res, cases)]
            fixed = [c for c, a, b in zip(cases, hit0, hit1) if b and not a]
            broken = [c for c, a, b in zip(cases, hit0, hit1) if a and not b]
            print(f"native w={weight}: +{len(fixed)}/-{len(broken)}")
            if args.verbose:
                for c in fixed:
                    print("    +", c[0], c[1], c[3])
                for c, r in zip(cases, res):
                    if c in broken:
                        print("    -", c[0], c[1], c[3], "->", r[0][0])
        return
    pairs = Path(args.pairs).expanduser()
    for min_count, cap, smooth in itertools.product(args.min_counts, args.caps, args.smooths):
        bg = Bigram(pairs, min_count, cap, smooth, lex.default if args.promo or args.signed else None, args.signed)
        for keep in args.top_pairs or [0]:
          if keep:
            print(f"top {keep:,} -> {bg.prune(keep, rank=args.rank):,} pairs")
          for weight in args.weights:
            fixed, broken = [], []
            for rows, c, hit in zip(decoded, cases, base_hit):
                new = rerank(rows, lex, bg, weight)
                now = bool(new) and new[0][0] == c[3]
                if now and not hit:
                    fixed.append(f"{c[0]}/{c[1]} {c[3]}")
                if hit and not now:
                    broken.append(f"{c[0]}/{c[1]} {c[3]} -> {new[0][0]}")
            print(f"min={min_count} cap={cap} smooth={smooth} w={weight}: +{len(fixed)}/-{len(broken)}")
            if args.verbose:
                for line in fixed:
                    print("    +", line)
                for line in broken:
                    print("    -", line)


def main():
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="cmd", required=True)
    b = sub.add_parser("build")
    b.add_argument("shards", nargs="+")
    b.add_argument("--resources", default=str(ROOT / "site/public"))
    b.add_argument("--out", required=True)
    b.add_argument("--groups", type=int, default=10**9, help="row groups to read")
    b.add_argument("--jobs", type=int, default=os.cpu_count() or 4)
    b.add_argument("--keep", type=int, default=3, help="drop pairs seen fewer times")
    x = sub.add_parser("export")
    x.add_argument("--pairs", required=True)
    x.add_argument("--out", required=True)
    x.add_argument("--min-count", type=int, default=3)
    x.add_argument("--cap", type=float, default=4.0)
    x.add_argument("--smooth", type=float, default=3.0)
    x.add_argument("--rank", default="pmi", choices=["pmi", "count", "impact", "sqrt"])
    x.add_argument("--top-pairs", type=int, default=400000)
    e = sub.add_parser("eval")
    e.add_argument("--pairs", required=True)
    e.add_argument("--resources", default=str(ROOT / "site/public"))
    e.add_argument("--min-counts", type=int, nargs="+", default=[3, 10])
    e.add_argument("--caps", type=float, nargs="+", default=[2.0, 4.0])
    e.add_argument("--smooths", type=float, nargs="+", default=[0.0, 20.0, 100.0])
    e.add_argument("--weights", type=float, nargs="+", default=[0.5, 1.0, 2.0])
    e.add_argument("--shard", nargs="+", help="parquet shard the pairs came from; drop sentences found verbatim")
    e.add_argument("--promo", action="store_true", help="promotion-only, relative to the homophone default")
    e.add_argument("--signed", action="store_true", help="relative to the homophone default, demotions kept")
    e.add_argument("--native", action="store_true", help="evaluate the Zig core's rerank (resources/homophone.bin)")
    e.add_argument("--rank", default="pmi", choices=["pmi", "count", "impact", "sqrt"])
    e.add_argument("--top-pairs", type=int, nargs="+", help="keep only the K largest |PMI| pairs")
    e.add_argument("--cv-count", type=int, default=0)
    e.add_argument("--extra", nargs="*", default=[], help="TEXT=KEYS cases")
    e.add_argument("--verbose", action="store_true")
    args = parser.parse_args()
    {"build": build, "export": export, "eval": evaluate}[args.cmd](args)


if __name__ == "__main__":
    main()
