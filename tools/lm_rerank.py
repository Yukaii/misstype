"""LM rerank experiment, scoring edition (M4 validation, tools-only, opt-in).

QingJian-style question: can a small LOCAL model rerank offline top-N by
fluency, where generative repair already failed? Unlike tools/lm_rescore.py
(free generation: echoes, hallucinations), this only SCORES the engine's own
candidates, so it cannot invent text — worst case it keeps offline top-1.

Method (exact, no detokenization hacks): build a character trie over the
top-N candidates; at each branching node, one llama-server request scores
P(first token of each child char | common prefix). Single-token branches
only (asserted via /tokenize; Chinese chars qualify). Candidate score is
the sum of edge logprobs along its path.

Needs: llama-server on :8081 with a local GGUF (this was validated with
qwen2.5-0.5b extracted from the local ollama blob store — no downloads).
Offline acoustic scores stay untouched; the verdict compares pure-LM rank
against offline top-1. Exits 0 (report, not gate).

Usage:
    python tools/lm_rerank.py [--top 8] [--n-probs 200]
"""

import argparse
import json
import subprocess
import sys
import time
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
APP_BIN = ROOT / "dist/MistypeIME.app/Contents/MacOS/MistypeIME"
SERVER = "http://localhost:8081"
FLOOR = -12.0

CASES = [
    # Full truth needs 不打/嗎 recall work (outside top-8 by design today);
    # the LM case below isolates the 便/辨 decision, which IS in reach.
    {"name": "辨識", "keys": "clivu0y9d0d0cjo1jcjo1urulclbjeji1j28g/2ulc9dku1u0gt/ej/a8",
     "expected": "好喔現在看看會不會比較好如果不大聲調還可以辨識成功麼"},
    {"name": "打對", "keys": "hkguvu8cjo1jcjo282jo",
     "expected": "測試一下會不會打對"},
    {"name": "control-toned", "keys": "su3cl3", "expected": "你好"},
    {"name": "control-wrongtone", "keys": "su4cl4", "expected": "你好"},
]


def api(path: str, obj: dict, timeout: float = 120.0) -> dict:
    req = urllib.request.Request(SERVER + path, data=json.dumps(obj).encode(),
                                 headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return json.loads(resp.read())


def offline_top(keys: str, limit: int) -> list[tuple[str, float]]:
    proc = subprocess.run([str(APP_BIN), "--decode", keys], capture_output=True,
                          text=True, timeout=180)
    out = []
    for line in proc.stdout.splitlines()[1:1 + limit]:
        fields = line.split("\t")
        if fields and fields[0]:
            out.append((fields[0], float(fields[1])))
    return out


def tokenize(text: str) -> list[int]:
    return api("/tokenize", {"content": text})["tokens"]


def edge_scores(prefix: str, children: list[str], n_probs: int) -> tuple[dict[str, float], float]:
    """Logprob of each single-token child char given the common prefix.

    Instruct models misbehave on bare prefixes (mass on 答案/Engl-style
    continuations), so score inside the chat template the model was tuned
    for: completing the sentence with exactly one more character.
    """
    started = time.perf_counter()
    prompt = ("<|im_start|>user\n請寫出這個繁體中文句子接下來最合理的一個字，"
              "只輸出那一個字，不要解釋。句子："
              + prefix + "<|im_end|>\n<|im_start|>assistant\n")
    resp = api("/completion", {"prompt": prompt, "n_predict": 1, "temperature": 0.0,
                               "n_probs": n_probs, "cache_prompt": False})
    elapsed_ms = (time.perf_counter() - started) * 1000
    entries = (resp.get("completion_probabilities") or [{}])[0].get("top_logprobs", [])
    table = {entry["id"]: entry["logprob"] for entry in entries}
    scores = {}
    for char in children:
        ids = tokenize(char)
        assert len(ids) == 1, f"multi-token branch {char!r}: {ids}"
        scores[char] = table.get(ids[0], FLOOR)
    return scores, elapsed_ms


def rerank(candidates: list[tuple[str, float]], n_probs: int
           ) -> tuple[list[tuple[str, float]], list[tuple[str, float]], float, int]:
    """Character-trie LM scoring. Returns [(text, lm, acoustic)], reqs, ms.
    Ties keep acoustic order (index tiebreak) — the LM refines, never
    re-sorts blindly. Empty-prefix roots are skipped (no logprobs)."""
    texts = [t for t, _ in candidates]
    acoustic = {t: s for t, s in candidates}
    order = {t: i for i, (t, _) in enumerate(candidates)}
    total_ms, requests = 0.0, 0
    scores = {t: 0.0 for t, _ in candidates}
    # Group by common prefix recursively (iterative stack of index lists).
    # Empty-prefix roots are skipped (server returns no logprobs for them);
    # ties keep acoustic order via the index tiebreak below.
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
            # One side ended (shorter candidate): no divergence to score.
            stack.extend([v for v in buckets.values() if len(v) > 1])
            continue
        children = sorted(buckets)
        table, ms = edge_scores(prefix, children, n_probs)
        total_ms += ms
        requests += 1
        for char, idxs in buckets.items():
            for idx in idxs:
                scores[texts[idx]] += table[char]
            if len(idxs) > 1:
                stack.append(idxs)
    ranked = sorted(scores.items(), key=lambda kv: (-kv[1], order[kv[0]]))
    combined = sorted(scores.items(),
                      key=lambda kv: (-(acoustic[kv[0]] + kv[1]), order[kv[0]]))
    return ranked, combined, total_ms, requests


def verdict(kind: str, top: str, expected: str, baseline: str) -> str:
    if top == expected and baseline != top:
        return "FLIP"
    return "SAME" if top == baseline else "WORSE"


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--top", type=int, default=8)
    parser.add_argument("--n-probs", type=int, default=200)
    args = parser.parse_args()

    flips = same = worse = 0
    for case in CASES:
        print(f"--- {case['name']} expected={case['expected']}")
        candidates = offline_top(case["keys"], args.top)
        texts = [t for t, _ in candidates]
        if case["expected"] not in texts:
            print(f"  [recall-miss] truth outside top-{args.top}; LM cannot help")
            worse += 1
            continue
        ranked, combined, ms, reqs = rerank(candidates, args.n_probs)
        top1 = texts[0]
        top_lm, top_mix = ranked[0][0], combined[0][0]
        mark_lm = verdict("lm", top_lm, case["expected"], top1)
        mark_mix = verdict("mix", top_mix, case["expected"], top1)
        print(f"  offline top1={top1}")
        print(f"  lm      top1={top_lm} ({reqs} reqs, {ms:.0f}ms) [{mark_lm}]")
        print(f"  lm+acou  top1={top_mix} [{mark_mix}]")
        print("  lm rank:", " / ".join(f"{t}({s:.1f})" for t, s in ranked[:4]))
        flips += (mark_lm == "FLIP") + (mark_mix == "FLIP")
        same += (mark_lm == "SAME") + (mark_mix == "SAME")
        worse += (mark_lm == "WORSE") + (mark_mix == "WORSE")
    print(f"result: flips={flips} same={same} worse={worse}")
    return 0 if worse == 0 else 1


if __name__ == "__main__":
    raise SystemExit(main())
