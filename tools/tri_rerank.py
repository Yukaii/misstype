"""Trigram-rerank experiment (tools-only, no server, deterministic).

Same protocol as tools/lm_rerank.py — character-trie divergence scoring
over offline top-8, pure and acoustic-combined verdicts — but the scorer
is LCCC corpus counts (tools/corpus_bigram.py) instead of a Transformer.
Two-pass for memory: collect needed (a,b,c)/(a,b) keys from the candidates
first, then grep-extract only those lines from the 400MB tables.

Verdict decides the count-model family after bigram was falsified. The
recall wall stands: full truths needing 不打/嗎 are outside top-8, so the
measurable claims are 打對/辨識-partial flips + control stability.

Usage:
    python tools/tri_rerank.py [--top 8]
Exits 0 (report, not gate).
"""

import os
import argparse
import subprocess
import sys
import tempfile
from pathlib import Path

CACHE = Path.home() / ".cache/misstype/corpus"
ROOT = Path(__file__).resolve().parent.parent
APP_BIN = ROOT / "core-zig/zig-out/bin/misstype-dev"  # cd core-zig && zig build
os.environ.setdefault("MISSTYPE_RESOURCES", str(ROOT / "dist/MisstypeIME.app/Contents/Resources"))
FLOOR = -12.0

CASES = [
    {"name": "辨識", "keys": "clivu0y9d0d0cjo1jcjo1urulclbjeji1j28g/2ulc9dku1u0gt/ej/a8",
     "expected": "好喔現在看看會不會比較好如果不大聲調還可以辨識成功麼"},
    {"name": "打對", "keys": "hkguvu8cjo1jcjo282jo",
     "expected": "測試一下會不會打對"},
    {"name": "control-toned", "keys": "su3cl3", "expected": "你好"},
    {"name": "control-wrongtone", "keys": "su4cl4", "expected": "你好"},
]


def offline_top(keys: str, limit: int) -> list[tuple[str, float]]:
    proc = subprocess.run([str(APP_BIN), "--decode", keys], capture_output=True,
                          text=True, timeout=180)
    out = []
    for line in proc.stdout.splitlines()[1:1 + limit]:
        fields = line.split("\t")
        if fields and fields[0]:
            out.append((fields[0], float(fields[1])))
    return out


def collect_keys(candidates: list[str]) -> tuple[set[str], set[str]]:
    """Trie walk collecting needed trigram (a,b,c) and bigram (a,b) keys."""
    tris, bis = set(), set()
    stack = [list(range(len(candidates)))]
    while stack:
        group = stack.pop()
        if len(group) < 2:
            continue
        texts = [candidates[i] for i in group]
        common = 0
        while all(len(t) > common and t[common] == texts[0][common] for t in texts):
            common += 1
        prefix, rest = texts[0][:common], [t[common:] for t in texts]
        buckets: dict[str, list[int]] = {}
        for idx, tail in zip(group, rest):
            if tail:
                buckets.setdefault(tail[0], []).append(idx)
        if len(buckets) < 2:
            stack.extend([v for v in buckets.values() if len(v) > 1])
            continue
        for char in buckets:
            if len(prefix) >= 2:
                tris.add(prefix[-2] + "\t" + prefix[-1] + "\t" + char)
            elif len(prefix) == 1:
                bis.add(prefix[-1] + "\t" + char)
        for idxs in buckets.values():
            if len(idxs) > 1:
                stack.append(idxs)
    return tris, bis


def extract(table: Path, keys: set[str]) -> dict[str, float]:
    """Grep-extract matching lines (fixed strings) into a small dict."""
    if not keys:
        return {}
    with tempfile.NamedTemporaryFile(mode="w", suffix=".txt", delete=False) as patterns:
        patterns.write("\n".join(sorted(keys)) + "\n")
    proc = subprocess.run(["grep", "-F", "-f", patterns.name, str(table)],
                          capture_output=True, text=True)
    Path(patterns.name).unlink()
    table_map = {}
    for line in proc.stdout.splitlines():
        fields = line.split("\t")
        if len(fields) == 4:
            table_map[fields[0] + "\t" + fields[1] + "\t" + fields[2]] = float(fields[3])
        elif len(fields) == 3:
            table_map[fields[0] + "\t" + fields[1]] = float(fields[2])
    return table_map


def verdict(top: str, expected: str, baseline: str) -> str:
    if top == expected and baseline != top:
        return "FLIP"
    return "SAME" if top == baseline else "WORSE"


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--top", type=int, default=8)
    args = parser.parse_args()

    all_tris, all_bis, case_cands = set(), set(), {}
    for case in CASES:
        candidates = offline_top(case["keys"], args.top)
        case_cands[case["name"]] = (case, candidates)
        texts = [t for t, _ in candidates]
        if case["expected"] in texts:
            tris, bis = collect_keys(texts)
            all_tris |= tris
            all_bis |= bis
    print(f"needed keys: {len(all_tris)} trigrams, {len(all_bis)} bigrams")
    tri = extract(CACHE / "trigrams-corpus.tsv", all_tris)
    bi = extract(CACHE / "bigrams-corpus.tsv", all_bis)
    print(f"matched: {len(tri)} trigrams, {len(bi)} bigrams")

    flips = same = worse = 0
    for name, (case, candidates) in case_cands.items():
        print(f"--- {name} expected={case['expected']}")
        texts = [t for t, _ in candidates]
        acoustic = {t: s for t, s in candidates}
        order = {t: i for i, (t, _) in enumerate(candidates)}
        if case["expected"] not in texts:
            print(f"  [recall-miss] truth outside top-{args.top}")
            worse += 1
            continue
        scores = {t: 0.0 for t in texts}
        stack = [list(range(len(texts)))]
        while stack:
            group = stack.pop()
            if len(group) < 2:
                continue
            group_texts = [texts[i] for i in group]
            common = 0
            while all(len(t) > common and t[common] == group_texts[0][common] for t in group_texts):
                common += 1
            if common == 0:
                continue
            prefix, rest = group_texts[0][:common], [t[common:] for t in group_texts]
            buckets: dict[str, list[int]] = {}
            for idx, tail in zip(group, rest):
                if tail:
                    buckets.setdefault(tail[0], []).append(idx)
            if len(buckets) < 2:
                stack.extend([v for v in buckets.values() if len(v) > 1])
                continue
            for char, idxs in buckets.items():
                if len(prefix) >= 2:
                    value = tri.get(prefix[-2] + "\t" + prefix[-1] + "\t" + char, FLOOR)
                else:
                    value = bi.get(prefix[-1] + "\t" + char, FLOOR) if prefix else 0.0
                for idx in idxs:
                    scores[texts[idx]] += value
                if len(idxs) > 1:
                    stack.append(idxs)
        ranked = sorted(scores.items(), key=lambda kv: (-kv[1], order[kv[0]]))
        combined = sorted(scores.items(),
                          key=lambda kv: (-(acoustic[kv[0]] + kv[1]), order[kv[0]]))
        top1, top_tri, top_mix = texts[0], ranked[0][0], combined[0][0]
        mark_tri, mark_mix = verdict(top_tri, case["expected"], top1), verdict(top_mix, case["expected"], top1)
        print(f"  offline top1={top1}")
        print(f"  tri     top1={top_tri} [{mark_tri}]")
        print(f"  tri+acou top1={top_mix} [{mark_mix}]")
        print("  tri rank:", " / ".join(f"{t}({s:.1f})" for t, s in ranked[:4]))
        flips += (mark_tri == "FLIP") + (mark_mix == "FLIP")
        same += (mark_tri == "SAME") + (mark_mix == "SAME")
        worse += (mark_tri == "WORSE") + (mark_mix == "WORSE")
    print(f"result: flips={flips} same={same} worse={worse}")
    return 0 if worse == 0 else 1


if __name__ == "__main__":
    raise SystemExit(main())
