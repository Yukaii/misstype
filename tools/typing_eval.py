"""Simulated real-world typing: what does a typist actually end up with?

Question: the other tools measure one layer each (decode top-1, preview
stability, per-key cost). This one types whole synthetic sentences the way
people do — some skip tones, everyone mistypes, some notice and fix it at
once, mixed Chinese/English is entered the three ways people try (Shift tap
first, English typed in Zhuyin mode then Shift, no switch at all) — through
the real Zig `Session` (`misstype-dev --session-batch`), and scores the text
that was committed after Return.

The typist is open-loop and seeded: keystrokes depend only on (persona,
sentence, seed), never on what the engine shows, so two runs differ only
because the engine changed. Each case keeps its key sequence, so any case
replays with `misstype-dev --session-trace '<keys>' --show`.

Personas are assumptions, not measurements (error rates of skilled
typists are ~1-3 % of keystrokes, most noticed at once; see
docs/development.md, 打字評估). Calibrating them from real key logs is
open. Sentences are synthetic and hand-written, by category
(tools/eval/typing_corpus.tsv). Tune on dev; holdout only confirms.

Usage:
  (cd core-zig && zig build -Doptimize=ReleaseFast)   # Debug latency is meaningless
  python3 tools/typing_eval.py                       # dev+holdout, 2 seeds
  python3 tools/typing_eval.py --set dev --seeds 4 --failures 10
  python3 tools/typing_eval.py --save tools/baseline/typing_eval.json
  python3 tools/typing_eval.py --baseline tools/baseline/typing_eval.json [--fail-on-regression]

Offline and deterministic (latency aside); exits 0 unless
--fail-on-regression finds a group that lost exact sentences.
"""

import argparse
import hashlib
import json
import os
import random
import subprocess
import sys
import time
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass, field
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from cursor_replay import (APP_BIN, TONE_TO_KEY, ZHUYIN_TO_KEY,  # noqa: E402
                           load_reverse_lexicon, readings_for, split_tone)
from live_trace import stability  # noqa: E402

ROOT = Path(__file__).resolve().parent.parent
CORRECTION_PROTOCOL = "punctuation-escape-v1"

# Physical neighbours on the US layout Zhuyin keys sit on (keynoise.py's
# table, kept here so this tool needs no Python prototype import).
ROWS = ["1234567890-", "qwertyuiop", "asdfghjkl;", "zxcvbnm,./"]
NEIGHBORS = {ch: [o for r2, row2 in enumerate(ROWS) for c2, o in enumerate(row2)
                  if o != ch and abs(r - r2) <= 1 and abs(c - c2) <= 1]
             for r, row in enumerate(ROWS) for c, ch in enumerate(row)}


def cer(expected: str, got: str) -> float:
    """Character edit distance over the expected length."""
    previous = list(range(len(got) + 1))
    for i, a in enumerate(expected, 1):
        current = [i]
        for j, b in enumerate(got, 1):
            current.append(min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (a != b)))
        previous = current
    return previous[-1] / max(len(expected), 1)

CORPUS = Path(__file__).resolve().parent / "eval" / "typing_corpus.tsv"
PUNCT = set("，。？！：")


@dataclass(frozen=True)
class Persona:
    name: str
    tones: str  # "all" | "none" | "partial"
    error: float  # per symbol/letter keystroke
    notice: float  # chance an error is fixed at once (Backspace, retype)
    tone_error: float = 0.0  # wrong tone key (toned styles)
    tone_omit: float = 0.5  # "partial": chance a syllable's tone is skipped


PERSONAS = [
    # Controls: no typos, so every miss and every pick is the engine's.
    Persona("clean", "all", 0.0, 0.0),
    Persona("clean-toneless", "none", 0.0, 0.0),
    Persona("clean-partial-tones", "partial", 0.0, 0.0),
    Persona("careful", "all", 0.01, 0.9, tone_error=0.01),
    Persona("average", "all", 0.03, 0.7, tone_error=0.03),
    Persona("toneless", "none", 0.03, 0.6),
    Persona("partial-tones", "partial", 0.03, 0.6, tone_error=0.02),
    Persona("sloppy", "none", 0.07, 0.3),
]
# How mixed English is entered: Shift tap before the word, the word typed in
# Zhuyin mode and Shift tapped after it, or no switch (mixed recognition).
ENGLISH_METHODS = ("shift-first", "shift-after", "no-switch")
# Relative weights of error kinds (substitution of a neighbour dominates
# keyboard typos; transpositions and omissions follow).
ERROR_KINDS = (("substitute", 0.55), ("transpose", 0.2), ("omit", 0.15), ("insert", 0.1))


@dataclass
class Case:
    id: str
    track: str
    category: str
    persona: str
    set: str
    seed: int
    expected: str
    keys: str
    mixed_english: bool
    errors: int = 0
    result: dict = field(default_factory=dict)


def segments(sentence: str, reverse) -> list[tuple[str, str]]:
    """("zh", readings) | ("en", word) | ("space", " ") | ("punct", glyph)."""
    out: list[tuple[str, str]] = []
    i = 0
    while i < len(sentence):
        ch = sentence[i]
        j = i + 1
        if ch == " ":
            out.append(("space", " "))
        elif ch in PUNCT:
            out.append(("punct", ch))
        elif ch.isascii():
            while j < len(sentence) and sentence[j].isascii() and sentence[j] != " ":
                j += 1
            out.append(("en", sentence[i:j]))
        else:
            while j < len(sentence) and not sentence[j].isascii() and sentence[j] not in PUNCT:
                j += 1
            out.append(("zh", readings_for(sentence[i:j], reverse)))
        i = j
    return out


class Typist:
    def __init__(self, persona: Persona, rng: random.Random):
        self.p = persona
        self.rng = rng
        self.keys: list[str] = []
        self.errors = 0

    def letters(self, word: list[str]) -> None:
        """Type physical keys with persona errors and on-the-spot fixes."""
        i = 0
        while i < len(word):
            key = word[i]
            if self.rng.random() >= self.p.error:
                self.keys.append(key)
                i += 1
                continue
            kind = self.rng.choices([k for k, _ in ERROR_KINDS], [w for _, w in ERROR_KINDS])[0]
            noticed = self.rng.random() < self.p.notice
            near = NEIGHBORS.get(key.lower(), [])
            if kind == "transpose" and i + 1 < len(word):
                self.errors += 1
                self.keys += [word[i + 1], key] + (["⌫", "⌫", key, word[i + 1]] if noticed else [])
                i += 2
                continue
            if kind == "omit":
                self.errors += not noticed
                if noticed:
                    self.keys.append(key)
            elif kind == "insert" and near:
                self.errors += 1
                self.keys += [key, self.rng.choice(near)] + (["⌫"] if noticed else [])
            elif near:  # substitute (also a transpose at the word end)
                self.errors += 1
                self.keys += [self.rng.choice(near)] + (["⌫", key] if noticed else [])
            else:
                self.keys.append(key)
            i += 1

    def chinese(self, readings: str) -> None:
        for syllable in readings.split():
            base, tone = split_tone(syllable)
            self.letters([ZHUYIN_TO_KEY[s] for s in base])
            if self.p.tones == "none" or (self.p.tones == "partial" and self.rng.random() < self.p.tone_omit):
                continue
            tone_key = TONE_TO_KEY[tone]
            if self.rng.random() < self.p.tone_error:
                self.errors += 1
                self.keys.append(self.rng.choice([t for t in "3467 " if t != tone_key]))
                if self.rng.random() < self.p.notice:
                    self.errors -= 1
                    self.keys.append(tone_key)  # a late tone re-tones
                continue
            self.keys.append(tone_key)


def load_corpus(path: Path = CORPUS) -> list[tuple[str, str, str, str]]:
    """(set, category, sentence, readings) rows; `auto` rows go to dev or
    holdout by md5 parity of the sentence."""
    rows = []
    for line in path.read_text(encoding="utf-8").splitlines():
        if not line or line.startswith("#"):
            continue
        fields = line.split("\t") + [""]
        set_name, category, sentence, readings = fields[:4]
        if set_name == "auto":
            set_name = "holdout" if hashlib.md5(sentence.encode()).digest()[0] % 2 else "dev"
        if category == "mixed":
            set_name = f"mixed-{set_name}"
        rows.append((set_name, category, sentence, readings))
    return rows


def type_sentence(sentence: str, reverse, persona: Persona, method: str | None, rng,
                  readings: str = "") -> tuple[str, int]:
    typist = Typist(persona, rng)
    parts = [("zh", readings)] if readings else segments(sentence, reverse)
    latin = False
    for index, (kind, value) in enumerate(parts):
        if kind == "zh":
            if latin:
                typist.keys.append("⇧")
                latin = False
            typist.chinese(value)
        elif kind == "en":
            # A run already open (English word after English) needs no tap.
            if method == "shift-first" and not latin:
                typist.keys.append("⇧")
            typist.letters(list(value))
            if method == "shift-after" and not latin:
                typist.keys.append("⇧")
            latin = method != "no-switch"
        else:
            typist.keys.append(value)
    return "".join(typist.keys), typist.errors


def stable_rng(*parts: object) -> random.Random:
    digest = hashlib.md5("/".join(map(str, parts)).encode()).digest()
    return random.Random(int.from_bytes(digest[:8], "big"))


def build_cases(sets: list[str], seeds: int, methods: list[str]) -> list[Case]:
    reverse = load_reverse_lexicon()
    cases = []
    for set_name, category, sentence, readings in load_corpus():
        if set_name not in sets:
            continue
        mixed = set_name.startswith("mixed")
        for method in (methods if mixed else [None]):
            track = f"mixed:{method}" if mixed else "zh"
            for persona in PERSONAS:
                for seed in range(seeds):
                    rng = stable_rng(track, persona.name, sentence, seed)
                    keys, errors = type_sentence(sentence, reverse, persona, method, rng, readings)
                    cases.append(Case(
                        id=f"{track}|{persona.name}|{seed}|{sentence}", track=track, category=category,
                        persona=persona.name, set=set_name, seed=seed, expected=sentence,
                        keys=keys, mixed_english=method == "no-switch", errors=errors))
    return cases


BIN = APP_BIN


def run_batch(cases: list[Case], mixed_english: bool) -> None:
    command = [str(BIN), "--session-batch", "-", "--show"] + (["--mixed-english"] if mixed_english else [])
    stdin = "".join(f"{case.keys}\t{case.expected}\n" for case in cases)
    proc = subprocess.run(command, input=stdin, capture_output=True, text=True, check=True, timeout=1800)
    lines = proc.stdout.splitlines()
    if len(lines) != len(cases):
        raise RuntimeError(f"misstype-dev returned {len(lines)} results for {len(cases)} cases")
    for case, line in zip(cases, lines):
        case.result = json.loads(line)


def run(cases: list[Case], jobs: int) -> None:
    chunks = []
    for mixed in (False, True):
        group = [c for c in cases if c.mixed_english == mixed]
        size = max(1, -(-len(group) // jobs))
        chunks += [(group[i:i + size], mixed) for i in range(0, len(group), size)]
    with ThreadPoolExecutor(max_workers=jobs) as pool:
        list(pool.map(lambda chunk: run_batch(*chunk), chunks))


def percentile(values: list[float], q: float) -> float:
    if not values:
        return 0.0
    ordered = sorted(values)
    return ordered[min(len(ordered) - 1, int(q * len(ordered)))]


def squash(text: str) -> str:
    return text.replace(" ", "")


def score(cases: list[Case]) -> tuple[dict, dict]:
    """Per case: what was shown before any pick (`exact` = no pick needed),
    and what the panel typist reached (`picks`, `fix_keys`, `reached`)."""
    per_case = {}
    groups: dict[str, list[Case]] = {}
    for case in cases:
        r = case.result
        views = [v.replace("|", "", 1) for v in r.get("views", [])]
        bare = squash(case.expected)
        per_case[case.id] = {
            "shown": r["before_fix"], "final": r["final"], "keys": case.keys,
            # Spaces are layout no pick can fix: scored apart (space_lost).
            "exact": squash(r["before_fix"]) == bare,
            "reached": squash(r["final"]) == bare,
            "space_lost": squash(r["final"]) == bare and r["final"] != case.expected,
            "picks": r["picks"], "fix_keys": r["fix_keys"],
            "cer": round(cer(bare, squash(r["before_fix"])), 4),
            **{k: v for k, v in stability(views).items() if k in ("revert_steps", "churn_steps")},
        }
        for key in (f"{case.track} | {case.set}", f"{case.track} | {case.persona}", f"ALL | {case.set}",
                    f"{case.track} | cat:{case.category}"):
            groups.setdefault(key, []).append(case)
    summary = {}
    for key, members in sorted(groups.items()):
        rows = [per_case[c.id] for c in members]
        ms = [m for c in members for m in c.result["ms"]]
        chars = sum(len(c.expected) for c in members)
        n = len(rows)
        reached = [row for row in rows if row["reached"]]
        summary[key] = {
            "n": n,
            "exact": sum(row["exact"] for row in rows),
            "exact_pct": round(100 * sum(row["exact"] for row in rows) / n, 1),
            # Selections per 100 characters, over sentences the panel fixes.
            "picks_100": round(100 * sum(row["picks"] for row in reached)
                               / max(sum(len(c.expected) for c in members if per_case[c.id]["reached"]), 1), 2),
            "fix_keys": round(sum(row["fix_keys"] for row in reached) / max(len(reached), 1), 2),
            "unreach_pct": round(100 * (n - len(reached)) / n, 1),
            "space_lost": sum(row["space_lost"] for row in rows),
            "cer_pct": round(100 * sum(row["cer"] for row in rows) / n, 2),
            "kspc": round(sum(len(c.keys) for c in members) / chars, 2),
            "uncorrected_errors": sum(c.errors for c in members),
            "revert_steps": sum(row["revert_steps"] for row in rows),
            "churn_steps": sum(row["churn_steps"] for row in rows),
            "ms_p50": round(percentile(ms, 0.5), 2),
            "ms_p95": round(percentile(ms, 0.95), 2),
            "ms_max": round(max(ms, default=0.0), 1),
        }
    return summary, per_case


COLUMNS = ("n", "exact_pct", "picks_100", "fix_keys", "unreach_pct", "space_lost", "cer_pct", "kspc",
           "churn_steps", "ms_p95", "ms_max")
DELTA_COLUMNS = ("exact_pct", "picks_100", "fix_keys", "unreach_pct", "space_lost", "cer_pct", "churn_steps")


def print_summary(summary: dict, baseline: dict | None) -> None:
    print(f"{'group':38} " + " ".join(f"{c:>12}" for c in COLUMNS))
    for key, row in summary.items():
        cells = []
        for c in COLUMNS:
            cell = f"{row[c]}"
            if baseline and key in baseline and c in DELTA_COLUMNS and c in baseline[key]:
                delta = row[c] - baseline[key][c]
                if delta:
                    cell += f"({delta:+.1f})" if isinstance(delta, float) else f"({delta:+d})"
            cells.append(f"{cell:>12}")
        print(f"{key:38} " + " ".join(cells))


def cost(row: dict) -> float:
    """Picks the typist needed; a sentence the panel cannot fix costs more
    than any number of picks."""
    return row["picks"] if row["reached"] else float("inf")


def compare(per_case: dict, base_cases: dict, limit: int) -> tuple[list, list]:
    """Cases that need fewer / more picks than in the baseline (reaching a
    sentence the panel could not fix counts as fewer)."""
    better, worse = [], []
    for case_id, row in per_case.items():
        old = base_cases.get(case_id)
        if old is None or cost(old) == cost(row):
            continue
        (better if cost(row) < cost(old) else worse).append((case_id, old, row))
    for title, items in (("FEWER PICKS", better), ("MORE PICKS", worse)):
        print(f"\n{title}: {len(items)}")
        for case_id, old, row in items[:limit]:
            def show(r):
                return f"{r['shown']!r} picks={r['picks'] if r['reached'] else 'unreachable'}"
            print(f"  {case_id}\n    was {show(old)}\n    now {show(row)}\n    keys {row['keys']}")
    return better, worse


def save(path: Path, meta: dict, summary: dict, per_case: dict) -> None:
    """JSON with one line per case, so a baseline update diffs as the cases
    that changed."""
    path.parent.mkdir(parents=True, exist_ok=True)
    meta = {**meta, "correction_protocol": CORRECTION_PROTOCOL}
    dump = lambda value: json.dumps(value, ensure_ascii=False, sort_keys=True)  # noqa: E731
    fields = ("exact", "reached", "picks", "fix_keys", "shown", "final", "keys")
    cases = ",\n".join(f"  {dump(case_id)}: {dump({k: row[k] for k in fields})}"
                        for case_id, row in sorted(per_case.items()))
    groups = ",\n".join(f"  {dump(key)}: {dump(row)}" for key, row in summary.items())
    path.write_text(f'{{"meta": {dump(meta)},\n"summary": {{\n{groups}\n}},\n"cases": {{\n{cases}\n}}}}\n',
                    encoding="utf-8")


def git_commit() -> str:
    try:
        commit = subprocess.run(["git", "rev-parse", "--short", "HEAD"], cwd=ROOT, capture_output=True,
                                text=True, check=True).stdout.strip()
        dirty = subprocess.run(["git", "diff", "--quiet", "HEAD"], cwd=ROOT,
                               capture_output=True).returncode == 1
        return commit + ("-dirty" if dirty else "")
    except (OSError, subprocess.CalledProcessError):
        return "unknown"


def learning(personas: list[str]) -> int:
    """Learning over a day of typing: one engine per persona (`--carry`)
    types dev (first), dev again (repeat), then holdout (transfer); each
    pass is compared with the same keys on a fresh engine. Fewer picks on
    repeat is memory, on transfer generalization; more picks on transfer is
    collateral damage from what was learned. One seed only: a second seed
    of a sentence would be a repeat inside the first pass."""
    reverse = load_reverse_lexicon()
    corpus = [r for r in load_corpus() if r[0] in ("dev", "holdout")]
    by_name = {p.name: p for p in PERSONAS}
    passes = (("first", "dev"), ("repeat", "dev"), ("transfer", "holdout"))
    for name in personas:
        persona = by_name[name]
        lines, tags = [], []
        for pass_name, set_name in passes:
            for row_set, category, sentence, readings in corpus:
                if row_set != set_name:
                    continue
                keys, _ = type_sentence(sentence, reverse, persona, None,
                                        stable_rng("zh", name, sentence, 0), readings)
                lines.append(f"{keys}\t{sentence}\n")
                tags.append((pass_name, sentence, category))
        def batch(carry: bool) -> list[dict]:
            command = [str(BIN), "--session-batch", "-"] + (["--carry"] if carry else [])
            out = subprocess.run(command, input="".join(lines), capture_output=True, text=True,
                                 check=True, timeout=1800).stdout.splitlines()
            return [json.loads(line) for line in out]
        fresh, carried = batch(False), batch(True)
        print(f"\n{name}: {'pass':9} {'n':>5} {'fresh picks/100':>16} {'learned':>8} {'fewer':>6} {'more':>5}")
        worse_examples = []
        for pass_name, _ in passes:
            idx = [i for i, t in enumerate(tags) if t[0] == pass_name]
            chars = sum(len(tags[i][1]) for i in idx)
            cost = lambda rs, i: rs[i]["picks"] if rs[i]["final"] == tags[i][1] else 99  # noqa: E731
            per100 = lambda rs: 100 * sum(rs[i]["picks"] for i in idx if rs[i]["final"] == tags[i][1]) / chars  # noqa: E731
            fewer = sum(cost(carried, i) < cost(fresh, i) for i in idx)
            more = [i for i in idx if cost(carried, i) > cost(fresh, i)]
            worse_examples += [(pass_name, tags[i][1], fresh[i]["before_fix"], carried[i]["before_fix"]) for i in more]
            print(f"{'':{len(name) + 1}} {pass_name:9} {len(idx):5} {per100(fresh):16.2f} {per100(carried):8.2f} "
                  f"{fewer:6} {len(more):5}")
        for pass_name, want, was, now in worse_examples[:12]:
            print(f"   worse ({pass_name}): {want}  fresh {was}  learned {now}")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description="Simulated real-world typing evaluation")
    parser.add_argument("--set", choices=["dev", "holdout", "all"], default="all",
                        help="dev = dev + mixed-dev; holdout = holdout + mixed-holdout")
    parser.add_argument("--seeds", type=int, default=2)
    parser.add_argument("--methods", default=",".join(ENGLISH_METHODS),
                        help="mixed-English entry methods, comma-separated")
    parser.add_argument("--jobs", type=int, default=min(8, os.cpu_count() or 1))
    parser.add_argument("--failures", type=int, default=0, help="print N failing cases per track")
    parser.add_argument("--save", type=Path, help="write summary + per-case results (a baseline)")
    parser.add_argument("--baseline", type=Path, help="compare against a saved run")
    parser.add_argument("--limit", type=int, default=15, help="fixed/broken cases to print")
    parser.add_argument("--fail-on-regression", action="store_true")
    parser.add_argument("--learning", default="",
                        help="comma-separated personas: run the learning passes instead")
    parser.add_argument("--bin", type=Path, default=APP_BIN,
                        help="misstype-dev to drive (e.g. another worktree's build)")
    args = parser.parse_args()
    global BIN
    BIN = args.bin
    if not BIN.exists():
        print("missing build: (cd core-zig && zig build -Doptimize=ReleaseFast)")
        return 2
    mode = subprocess.run([str(BIN), "--build-mode"], capture_output=True, text=True).stdout.strip() or "unknown"
    if mode not in ("fast", "ReleaseFast"):
        print(f"note: misstype-dev is a {mode} build; latency columns are not comparable", file=sys.stderr)
    if args.learning:
        return learning([p for p in args.learning.split(",") if p])
    sets = {"dev": ["dev", "mixed-dev"], "holdout": ["holdout", "mixed-holdout"],
            "all": ["dev", "holdout", "mixed-dev", "mixed-holdout"]}[args.set]
    methods = [m for m in args.methods.split(",") if m]
    started = time.perf_counter()
    cases = build_cases(sets, args.seeds, methods)
    run(cases, args.jobs)
    summary, per_case = score(cases)
    baseline = json.loads(args.baseline.read_text(encoding="utf-8")) if args.baseline else None
    print_summary(summary, baseline["summary"] if baseline else None)
    print(f"\n{len(cases)} cases, {time.perf_counter() - started:.1f}s, offline, {mode}, "
          f"{args.jobs} jobs, commit {git_commit()}")
    if args.failures:
        for track in sorted({c.track for c in cases}):
            misses = [c for c in cases if c.track == track and not per_case[c.id]["exact"]]
            print(f"\n{track}: {len(misses)} need picks or retyping")
            for case in misses[:args.failures]:
                row = per_case[case.id]
                outcome = f"{row['picks']} picks" if row["reached"] else "unreachable"
                print(f"  [{case.persona}] {case.expected} -> {row['shown']} ({outcome})\n    keys {case.keys}")
    worse: list = []
    if baseline:
        _, worse = compare(per_case, baseline["cases"], args.limit)
    if args.save:
        save(args.save, {"commit": git_commit(), "seeds": args.seeds, "set": args.set, "methods": methods,
                         "build": mode, "jobs": args.jobs}, summary, per_case)
        print(f"saved {args.save}")
    if args.fail_on_regression and baseline:
        old = baseline["summary"]
        lost = [k for k, row in summary.items() if k in old and "picks_100" in old[k]
                and (row["exact"] < old[k]["exact"] or row["unreach_pct"] > old[k]["unreach_pct"]
                     or row["picks_100"] > old[k]["picks_100"])]
        if lost or worse:
            print(f"\nREGRESSION: {len(worse)} cases need more picks; groups worse: {', '.join(lost) or '-'}")
            return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
