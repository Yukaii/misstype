"""LM repair experiment (M4 validation, tools-only, opt-in).

Question: can a small local model repair the homophone ties that the
offline unigram decoder cannot (便是/辨識, 不大/不打, 麼/嗎, 大對/打對)?

Protocol mirrors decode_with_fallback semantics without touching runtime:
  1. Swift --decode produces offline top-N (single decoder implementation).
  2. qwen2.5 via localhost ollama proposes a repaired sentence (temp 0).
  3. Accept ONLY when: same length as offline top-1 AND every output char
     has a dictionary reading whose toneless base matches the input evidence
     at that position (anti-hallucination gate). Else fallback to top-1.
  4. Report CER before/after, per-stage latency, fallback events.

Fixtures are synthetic session cases (no personal text). Localhost only,
no API keys, no new runtime dependencies (stdlib urllib).

Usage:
  PYTHONPATH=src python tools/lm_rescore.py            # 0.5b model
  PYTHONPATH=src python tools/lm_rescore.py --model qwen2.5:1.5b
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
CACHE = ROOT / ".cache/mcbopomofo"
OLLAMA_URL = "http://localhost:11434/api/chat"

SYMBOLS = {
    "1": "ㄅ", "q": "ㄆ", "a": "ㄇ", "z": "ㄈ", "2": "ㄉ", "w": "ㄊ",
    "s": "ㄋ", "x": "ㄌ", "e": "ㄍ", "d": "ㄎ", "c": "ㄏ", "r": "ㄐ",
    "f": "ㄑ", "v": "ㄒ", "5": "ㄓ", "t": "ㄔ", "g": "ㄕ", "b": "ㄖ",
    "y": "ㄗ", "h": "ㄘ", "n": "ㄙ", "u": "ㄧ", "j": "ㄨ", "m": "ㄩ",
    "8": "ㄚ", "i": "ㄛ", "k": "ㄜ", ",": "ㄝ", "9": "ㄞ", "o": "ㄟ",
    "l": "ㄠ", ".": "ㄡ", "0": "ㄢ", "p": "ㄣ", ";": "ㄤ", "/": "ㄥ",
    "-": "ㄦ",
}
TONES = {"3": "ˇ", "4": "ˋ", "6": "ˊ", "7": "˙", " ": ""}
MARKS = set("ˊˇˋ˙")


def load_toneless_bases() -> set[str]:
    """Decoder-known toneless syllable bases (mirrors Swift toneless set)."""
    bases = set()
    for line in (CACHE / "lexicon.tsv").read_text().splitlines():
        for part in line.split("\t")[0].split("-"):
            bases.add("".join(c for c in part if c not in MARKS))
    return bases


def parse_keys(keys: str, toneless_bases: set[str]) -> list[str]:
    """Keystroke string -> per-syllable toneless bopomofo bases (evidence).

    Tone keys terminate like Composition.parse; toneless runs are segmented
    greedy longest-match (valid for clean typing; typos fail safe to
    fallback via the verification gate).
    """
    complete: list[str] = []
    pending: list[str] = []

    def segment_run(run: list[str]) -> list[str]:
        out, i = [], 0
        while i < len(run):
            for length in (3, 2, 1):
                if i + length <= len(run):
                    base = "".join(SYMBOLS[k] for k in run[i:i + length])
                    if base in toneless_bases:
                        out.append(base)
                        i += length
                        break
            else:
                out.append(SYMBOLS[run[i]])
                i += 1
        return out

    for key in keys:
        if key in TONES:
            if pending:
                base = "".join(SYMBOLS[k] for k in pending)
                complete.append(base)
                pending = []
        elif key in SYMBOLS:
            pending.append(key)
    if pending:
        complete.extend(segment_run(pending))
    return complete


def load_char_bases() -> dict[str, set[str]]:
    """Traditional char -> toneless bopomofo bases (BPMFBase, all readings)."""
    bases: dict[str, set[str]] = {}
    for line in (CACHE / "BPMFBase.txt").read_text().splitlines():
        fields = line.split()
        if len(fields) < 2 or len(fields[0]) != 1:
            continue
        base = "".join(c for c in fields[1] if c not in MARKS)
        bases.setdefault(fields[0], set()).add(base)
    return bases


def offline_top(keys: str, limit: int = 8) -> tuple[list[str], float]:
    started = time.perf_counter()
    proc = subprocess.run([str(APP_BIN), "--decode", keys], capture_output=True,
                          text=True, timeout=120)
    elapsed_ms = (time.perf_counter() - started) * 1000
    candidates = []
    for line in proc.stdout.splitlines()[1:1 + limit]:
        fields = line.split("\t")
        if fields and fields[0]:
            candidates.append(fields[0])
    return candidates, elapsed_ms


def lm_repair(evidence: list[str], candidates: list[str], model: str,
              timeout_s: float) -> tuple[str | None, float]:
    numbered = "\n".join(f"{i + 1}. {c}" for i, c in enumerate(candidates))
    prompt = (
        "你是注音輸入法校正器。注音證據（每音節："
        + " ".join(evidence)
        + "）。\n候選句：\n" + numbered
        + "\n選出最通順合理的一句，可將同音字微調（如麼→嗎、便是→辨識），"
          "但每字讀音必須與注音證據對應、字數必須與候選句相同。"
          "只輸出那一句，不要解釋、不要編號。"
    )
    body = json.dumps({"model": model, "temperature": 0, "stream": False,
                       "messages": [{"role": "user", "content": prompt}]}).encode()
    started = time.perf_counter()
    try:
        req = urllib.request.Request(OLLAMA_URL, data=body,
                                     headers={"Content-Type": "application/json"})
        with urllib.request.urlopen(req, timeout=timeout_s) as resp:
            reply = json.loads(resp.read())["message"]["content"]
    except Exception as error:
        print(f"  [lm-error] {type(error).__name__}: {error}")
        return None, (time.perf_counter() - started) * 1000
    elapsed_ms = (time.perf_counter() - started) * 1000
    for line in reply.strip().splitlines():
        text = line.strip().lstrip("0123456789.、 ").strip()
        if text:
            return text, elapsed_ms
    return None, elapsed_ms


def verify(output: str, evidence: list[str],
           char_bases: dict[str, set[str]]) -> bool:
    """Same length, and every char's base must match the evidence position."""
    if len(output) != len(evidence):
        print(f"  [gate] length {len(output)} != evidence {len(evidence)}")
        return False
    for char, base in zip(output, evidence):
        if base not in char_bases.get(char, set()):
            print(f"  [gate] {char} base mismatch (evidence {base}: "
                  f"{sorted(char_bases.get(char, set()))})")
            return False
    return True


def cer(hypothesis: str, reference: str) -> float:
    if not reference:
        return 0.0 if not hypothesis else 1.0
    shorter, longer = sorted((hypothesis, reference), key=len)
    if not longer:
        return 0.0
    previous = list(range(len(shorter) + 1))
    for long_char in longer:
        current = [previous[0] + 1]
        for j, short_char in enumerate(shorter):
            current.append(min(previous[j + (long_char != short_char)],
                               previous[j + 1] + 1, current[j] + 1))
        previous = current
    return previous[-1] / len(longer)


CASES = [
    {"name": "long-toneless", "model": None,
     "keys": "clivu0y9d0d0cjo1jcjo1urulclbjeji1j28g/2ulc9dku1u0gt/ej/a8",
     "expected": "好喔現在看看會不會比較好如果不打聲調還可以辨識成功嗎"},
    {"name": "dada-toneless", "model": None,
     "keys": "hkguvu8cjo1jcjo282jo",
     "expected": "測試一下會不會打對"},
    {"name": "nihao-wrongtone", "model": None,
     "keys": "su4cl4", "expected": "你好"},
    {"name": "nihao-toned-control", "model": None,
     "keys": "su3cl3", "expected": "你好"},
]


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--model", default="qwen2.5:0.5b")
    parser.add_argument("--timeout", type=float, default=120.0)
    args = parser.parse_args()
    char_bases = load_char_bases()
    toneless_bases = load_toneless_bases()
    print(f"char base coverage: {len(char_bases)} chars; model={args.model}")
    wins = falls = fallbacks = 0
    for case in CASES:
        print(f"--- {case['name']} expected={case['expected']}")
        candidates, decode_ms = offline_top(case["keys"])
        if not candidates:
            print("  [skip] no offline candidates"); falls += 1; continue
        top1 = candidates[0]
        print(f"  offline top1={top1} ({decode_ms:.0f}ms)")
        evidence = parse_keys(case["keys"], toneless_bases)
        proposal, lm_ms = lm_repair(evidence, candidates, args.model, args.timeout)
        if proposal is None or not verify(proposal, evidence, char_bases):
            fallbacks += 1
            print(f"  fallback top1 (lm {lm_ms:.0f}ms)")
            continue
        before, after = cer(top1, case["expected"]), cer(proposal, case["expected"])
        mark = "FLIP" if after < before else ("SAME" if after == before else "WORSE")
        print(f"  lm={proposal} ({lm_ms:.0f}ms) CER {before:.3f}->{after:.3f} [{mark}]")
        wins += after < before
        falls += after >= before
    print(f"result: flips={wins} same-or-worse={falls} fallbacks={fallbacks}")
    return 0 if falls == 0 else 1


if __name__ == "__main__":
    raise SystemExit(main())
