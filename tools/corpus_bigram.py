"""Char-bigram counts from LCCC dialogue (experiment data, not shipped).

Reads silver/lccc lccc_base_train.jsonl.gz (MIT per HF tags; pre-tokenized
dialogue turns), splits turns into Han runs on non-Han, and counts adjacent
Han pairs with add-one smoothed log P(curr | prev) — the same file format
prepare_lexicon.py once emitted, so the Swift loader is unchanged.

This isolates the DATA variable behind the falsified wordlist bigram:
same uniform-weight mechanism, corpus counts instead of wordlist pairs.

Usage:
    python tools/corpus_bigram.py [--limit N] [--probes]
Writes $HOME/.cache/mistype/corpus/bigrams-corpus.tsv (+ .stats.json).
Exits 0 (report, not gate).
"""

import argparse
import gzip
import json
import math
import os
import sys
from pathlib import Path


def is_han(char: str) -> bool:
    return "\u4e00" <= char <= "\u9fff"


SRC = (Path(os.path.expanduser("~")) / ".cache/mistype/corpus"
       / "lccc_base_train.jsonl.gz")
OUT = SRC.parent / "bigrams-corpus.tsv"

# Decision-relevant pairs for the 4-case battery (presence check only).
PROBES = ["以便", "以辨", "識成", "是成", "便士", "辨識",
          "不打", "不大", "功嗎", "功麼", "成更", "成功"]


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--limit", type=int, default=None)
    parser.add_argument("--probes", action="store_true")
    args = parser.parse_args()

    pair_counts: dict[tuple[str, str], int] = {}
    prev_totals: dict[str, int] = {}
    tri_counts: dict[tuple[str, str, str], int] = {}
    tri_totals: dict[tuple[str, str], int] = {}
    vocab: set[str] = set()
    lines = turns = 0

    def count_run(run: list[str]) -> None:
        for prev, curr in zip(run, run[1:]):
            pair_counts[(prev, curr)] = pair_counts.get((prev, curr), 0) + 1
            prev_totals[prev] = prev_totals.get(prev, 0) + 1
        for a, b, c in zip(run, run[1:], run[2:]):
            tri_counts[(a, b, c)] = tri_counts.get((a, b, c), 0) + 1
            tri_totals[(a, b)] = tri_totals.get((a, b), 0) + 1
        vocab.update(run)
    with gzip.open(SRC, "rt", encoding="utf-8", errors="replace") as handle:
        for raw in handle:
            raw = raw.strip()
            if not raw:
                continue
            lines += 1
            if args.limit is not None and lines > args.limit:
                break
            try:
                dialogue = json.loads(raw)
            except json.JSONDecodeError:
                continue
            utterances = dialogue if isinstance(dialogue, list) else [dialogue]
            for utterance in utterances:
                if not isinstance(utterance, str):
                    continue
                turns += 1
                run: list[str] = []
                for char in utterance.replace(" ", ""):
                    if is_han(char):
                        run.append(char)
                    else:
                        count_run(run)
                        run = []
                count_run(run)
            if lines % 200000 == 0:
                print(f"...{lines} dialogues", flush=True)

    total_pairs = sum(pair_counts.values())
    with open(OUT, "w", encoding="utf-8") as output:
        for (prev, curr) in sorted(pair_counts):
            prob = math.log((pair_counts[(prev, curr)] + 1)
                            / (prev_totals[prev] + len(vocab)))
            output.write(f"{prev}\t{curr}\t{prob:.6f}\n")
    tri_out = SRC.parent / "trigrams-corpus.tsv"
    with open(tri_out, "w", encoding="utf-8") as output:
        for (a, b, c) in sorted(tri_counts):
            prob = math.log((tri_counts[(a, b, c)] + 1)
                            / (tri_totals[(a, b)] + len(vocab)))
            output.write(f"{a}\t{b}\t{c}\t{prob:.6f}\n")
    stats = {"dialogues": lines, "turns": turns, "pairs": len(pair_counts),
             "pair_tokens": total_pairs, "chars": len(vocab), "file": str(OUT),
             "trigrams": len(tri_counts),
             "trigram_tokens": sum(tri_counts.values()),
             "trigram_file": str(tri_out)}
    (SRC.parent / "bigrams-corpus.stats.json").write_text(
        json.dumps(stats, ensure_ascii=False, indent=2), encoding="utf-8")
    print(json.dumps(stats, ensure_ascii=False, indent=2))
    if args.probes or True:
        for word in PROBES:
            got = [(pair_counts.get((word[i], word[i + 1]), 0)) for i in range(len(word) - 1)]
            print(f"probe {word}: {got}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
