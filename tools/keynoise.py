"""Seeded keyboard-error battery for the real Swift decoder (M3-style).

Usage:
    PYTHONPATH=src python tools/keynoise.py [--seeds 10] [--json]

For each probe sentence (correct keystrokes known), apply seeded key-level
noise — dropped/extra-free: missing keys, adjacent swaps (key ORDER slips),
neighbor substitutions, wrong tones, and dropped tones (the toneless case),
alone and combined — then decode via dist Swift --decode and report top-1
match, recall@8 (truth anywhere in the candidate list = rescorable later),
mean CER, and mean decode_ms. Offline only; exits 0 (report, not gate).

Complements tools/noise.py, which sweeps spatial touch jitter through the
Python fixture pipeline instead.
"""

import os
import argparse
import hashlib
import json
import random
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from bench import cer  # noqa: E402

ROOT = Path(__file__).resolve().parent.parent
APP_BIN = ROOT / "core-zig/zig-out/bin/misstype-dev"  # cd core-zig && zig build
os.environ.setdefault("MISSTYPE_RESOURCES", str(ROOT / "dist/MisstypeIME.app/Contents/Resources"))

TONE_KEYS = set("3467 ")
SYMBOL_ROWS = ["1234567890-", "qwertyuiop", "asdfghjkl;", "zxcvbnm,./"]
NEIGHBORS: dict[str, list[str]] = {}
for _r, _row in enumerate(SYMBOL_ROWS):
    for _c, _ch in enumerate(_row):
        near = []
        for _r2, _row2 in enumerate(SYMBOL_ROWS):
            for _c2, _ch2 in enumerate(_row2):
                if _ch2 != _ch and abs(_r - _r2) <= 1 and abs(_c - _c2) <= 1:
                    near.append(_ch2)
        NEIGHBORS[_ch] = near

# (name, correct toned keystrokes, expected text). Toneless variants are
# derived by stripping tone keys, so both styles share one truth.
# "*-phonetic" probes intentionally start from a phonetic slip (real user
# error class: ㄧㄨㄩ / sibilant confusion, far apart on QWERTY) to lock the
# confusion-repair capability with numbers.
PROBES = {
    "ni-hao": ("su3cl3", "你好"),
    "wo-shi-xue-sheng": ("ji3g4vm,6g/", "我是學生"),
    "dada": ("hk4g4u6vu84cjo41j6cjo42832jo4", "測試一下會不會打對"),
    "yue-lai-yue-phonetic": ("u,4x96u,4", "越來越"),
}


def apply_noise(keys: str, rng: random.Random, drop_key: float = 0.0,
                swap: float = 0.0, sub_key: float = 0.0,
                sub_tone: float = 0.0, no_tones: bool = False) -> str:
    """Seeded key-level corruption. Order slips, missing keys, wrong tones."""
    chars = [c for c in keys if not (no_tones and c in TONE_KEYS)]
    out = [c for c in chars if rng.random() >= drop_key]
    i = 0
    while i + 1 < len(out):
        if rng.random() < swap:
            out[i], out[i + 1] = out[i + 1], out[i]
            i += 2
        else:
            i += 1
    noisy = []
    for c in out:
        roll = rng.random()
        if c in TONE_KEYS:
            tones = [t for t in "3467 " if t != c]
            noisy.append(rng.choice(tones) if roll < sub_tone else c)
        else:
            near = NEIGHBORS.get(c, [])
            noisy.append(rng.choice(near) if near and roll < sub_key else c)
    return "".join(noisy)


CONFIGS = {
    "clean": {},
    "no-tones": {"no_tones": True},
    "drop-key-5": {"drop_key": 0.05},
    "swap-5": {"swap": 0.05},
    "sub-5+wrongtone-10": {"sub_key": 0.05, "sub_tone": 0.10},
    "harsh": {"no_tones": True, "drop_key": 0.05, "swap": 0.05,
              "sub_key": 0.05},
}


def decode_once(keys: str) -> tuple[list[str], float]:
    started = time.perf_counter()
    proc = subprocess.run([str(APP_BIN), "--decode", keys], capture_output=True,
                          text=True, timeout=120)
    elapsed_ms = (time.perf_counter() - started) * 1000
    candidates = [line.split("\t")[0] for line in proc.stdout.splitlines()[1:]
                  if line.split("\t")[0]]
    return candidates, elapsed_ms


def sweep(probes: dict, seeds: int) -> list[dict]:
    rows = []
    for name, (keys, expected) in probes.items():
        for config_name, kwargs in CONFIGS.items():
            top1 = recall = 0
            cers, decode_ms = [], []
            for seed in range(seeds):
                # Stable across processes (Python hash() is salted per run).
                digest = hashlib.md5(f"{name}/{config_name}/{seed}".encode()).digest()
                rng = random.Random(int.from_bytes(digest[:8], "big"))
                noisy = apply_noise(keys, rng, **kwargs)
                candidates, elapsed = decode_once(noisy)
                decode_ms.append(elapsed)
                if candidates and candidates[0] == expected:
                    top1 += 1
                if expected in candidates:
                    recall += 1
                cers.append(cer(expected, candidates[0] if candidates else ""))
            rows.append({
                "probe": name, "config": config_name, "seeds": seeds,
                "keys": keys, "expected": expected,
                "top1_match": top1 / seeds, "recall_at_8": recall / seeds,
                "mean_cer": sum(cers) / len(cers),
                "mean_decode_ms": sum(decode_ms) / len(decode_ms),
            })
    return rows


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Keyboard-error battery")
    parser.add_argument("--seeds", type=int, default=10)
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args(argv)

    rows = sweep(PROBES, args.seeds)
    if args.json:
        print(json.dumps(rows, ensure_ascii=False, indent=2))
        return 0
    print(f"{'probe':16} {'config':20} {'top1':5} {'rec@8':6} {'cer':6} {'ms':7}")
    for row in rows:
        print(f"{row['probe']:16} {row['config']:20} "
              f"{row['top1_match']:<5.2f} {row['recall_at_8']:<6.2f} "
              f"{row['mean_cer']:<6.3f} {row['mean_decode_ms']:<7.1f}")
    print("---")
    print("rec@8 - top1 = headroom for rescoring/UI; CER on top-1 only")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
