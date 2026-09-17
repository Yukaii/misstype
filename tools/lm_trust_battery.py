"""Trust-triage battery (M4 validation, tools-only, opt-in).

Question: does Jev's top-1 trust separate right from wrong top-1s across
the seeded keyboard-error battery (tools/keynoise.py), with a FROZEN
threshold, so it can drive candidate-window auto-show (triage, never
reranking)?

Pre-registered rule: threshold 0.6 (from the n=5 pilot, frozen before this
run). Correct = top-1 exactly equals expected (same definition as the
battery's top1_match). Verdict: miss-hide (wrong top-1 trusted >= 0.6,
panel stays hidden = REGRESSION vs today) must be 0 to proceed toward IME
wiring; miss-show (right top-1 distrusted = status quo noise) is reported
only. Errors/abstains are excluded from both rates and counted separately.

Reuses keynoise PROBES/CONFIGS/seeds verbatim (md5-stable) and lm_choose's
jev_trust (typed boolean on top-1, same state shape). Localhost Swift
--decode for the beam; only synthetic noisy keystroke decodes leave the
machine for Gateway. Key from environment or .env, never logged.

Usage:
  PYTHONPATH=src python tools/lm_trust_battery.py [--seeds 10]
  PYTHONPATH=src python tools/lm_trust_battery.py --seeds 2 --probe dada
"""

import argparse
import hashlib
import random
import statistics
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "tools"))

from bench import cer  # noqa: E402
from keynoise import CONFIGS, PROBES, apply_noise, decode_once  # noqa: E402
from lm_choose import jev_trust, load_dotenv  # noqa: E402

THRESHOLD = 0.6


def run_battery(seeds: int, probe_filter: str | None, api_key: str,
                timeout_s: float, topn: int) -> list[dict]:
    rows = []
    for name, (keys, expected) in PROBES.items():
        if probe_filter and name != probe_filter:
            continue
        for config_name, kwargs in CONFIGS.items():
            for seed in range(seeds):
                digest = hashlib.md5(
                    f"{name}/{config_name}/{seed}".encode()).digest()
                rng = random.Random(int.from_bytes(digest[:8], "big"))
                noisy = apply_noise(keys, rng, **kwargs)
                candidates, decode_ms = decode_once(noisy)
                if not candidates:
                    rows.append({"probe": name, "config": config_name,
                                 "seed": seed, "skipped": True})
                    continue
                top8 = candidates[:topn]
                top1 = top8[0]
                correct = top1 == expected
                trust, lm_ms = jev_trust(top8, "typesafe-ai/jev", api_key,
                                         timeout_s)
                rows.append({
                    "probe": name, "config": config_name, "seed": seed,
                    "keys": noisy, "expected": expected,
                    "top1": top1, "correct": correct, "trust": trust,
                    "cer": cer(expected, top1),
                    "decode_ms": decode_ms, "lm_ms": lm_ms,
                })
                time.sleep(0.1)  # Gateway politeness gap
    return rows


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--seeds", type=int, default=10)
    parser.add_argument("--probe", default=None)
    parser.add_argument("--timeout", type=float, default=120.0)
    parser.add_argument("--topn", type=int, default=8)
    parser.add_argument("--threshold", type=float, default=THRESHOLD)
    parser.add_argument("--dump-misses", action="store_true",
                        help="print every miss-hide row with keys/top-1/"
                             "expected/trust for inspection")
    args = parser.parse_args()
    api_key = (load_dotenv(ROOT / ".env").get("AI_GATEWAY_API_KEY", ""))
    if not api_key:
        print("refusing to run: AI_GATEWAY_API_KEY absent "
              "(environment or .env; never commit it)")
        return 2
    print(f"threshold={args.threshold} (frozen={THRESHOLD}) "
          f"seeds={args.seeds}")
    rows = run_battery(args.seeds, args.probe, api_key, args.timeout,
                       args.topn)
    judged = [r for r in rows if not r.get("skipped") and r["trust"] is not None]
    skipped = len(rows) - len(judged)
    hits = miss_show = miss_hide = 0
    by_cell: dict[tuple[str, str], list[float]] = {}
    for row in judged:
        hidden = row["trust"] >= args.threshold
        if hidden == row["correct"]:
            hits += 1
        elif hidden:
            miss_hide += 1
        else:
            miss_show += 1
        by_cell.setdefault((row["probe"], row["config"]), []).append(row["trust"])
    print(f"{'probe':20} {'config':20} {'n':4} {'hit':5} {'trust_mean':10}")
    for (probe, config), trusts in sorted(by_cell.items()):
        cell = [r for r in judged
                if r["probe"] == probe and r["config"] == config]
        cell_hits = sum((t >= args.threshold) == r["correct"]
                        for t, r in zip(trusts, cell))
        print(f"{probe:20} {config:20} {len(trusts):<4} "
              f"{cell_hits / len(trusts):<5.2f} "
              f"{statistics.mean(trusts):<10.2f}")
    trust_right = [r["trust"] for r in judged if r["correct"]]
    trust_wrong = [r["trust"] for r in judged if not r["correct"]]
    print(f"n={len(judged)} skipped={skipped} hits={hits} "
          f"miss_show={miss_show} miss_hide={miss_hide}")
    if args.dump_misses:
        for row in judged:
            if not row["correct"] and row["trust"] >= args.threshold:
                print(f"  MISS-HIDE {row['probe']}/{row['config']}/"
                      f"seed{row['seed']} trust={row['trust']:.2f} "
                      f"cer={row['cer']:.3f}\n"
                      f"    keys={row['keys']}\n"
                      f"    top1={row['top1']}\n"
                      f"    exp ={row['expected']}")
    if trust_right:
        print(f"trust|correct: mean={statistics.mean(trust_right):.2f} "
              f"min={min(trust_right):.2f} n={len(trust_right)}")
    if trust_wrong:
        print(f"trust|wrong:   mean={statistics.mean(trust_wrong):.2f} "
              f"max={max(trust_wrong):.2f} n={len(trust_wrong)}")
    return 0 if miss_hide == 0 else 1


if __name__ == "__main__":
    raise SystemExit(main())
