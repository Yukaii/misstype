"""Synthesize jittered touch traces to find where fuzziness stops helping.

Usage:
    PYTHONPATH=src python tools/noise.py [--seeds 20] [--json]

For each probe phrase, tap every key center with uniform-disk jitter of
radius r (normalized units, seeded, clamped to the surface), replay
through the real pipeline, and report the match rate per radius — once
with fuzzy alternatives and once with alternatives stripped (ablation).
The gap between the two columns is the measured contribution of
keyboard-neighborhood fuzziness. Offline only; exits 0 (report, not gate).
"""

import argparse
import json
import math
import random
import sys
from dataclasses import replace
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from mistype.normalize import normalize_events  # noqa: E402
from mistype.decoder import OfflineDecoder  # noqa: E402
from mistype.touch import key_position, touch_event  # noqa: E402

STEP_NS = 90_000_000

# (display name, physical key taps with tones, expected text). Toned taps
# keep the tone-optional fallback out of the picture, so the sweep isolates
# spatial error plus fuzzy rescue.
PROBES = {
    "ni-hao": (["s", "u", "3", "c", "l", "3"], "你好"),
    "zao-shang-hao": (["y", "l", "3", "g", ";", "4", "c", "l", "3"], "早上好"),
}

RADII = [0.0, 0.02, 0.05, 0.08, 0.10, 0.12, 0.15, 0.20]


def jitter_trace(keys: list[str], radius: float, seed: int,
                 session_id: str = "noise") -> list:
    """Tap key centers with seeded uniform-disk jitter; radius 0 is exact."""
    rng = random.Random(seed)
    events = []
    for i, key in enumerate(keys):
        surface, (x, y) = key_position(key)
        if radius > 0:
            angle = rng.uniform(0, 2 * math.pi)
            distance = rng.uniform(0, radius)
            x = min(1.0, max(0.0, x + distance * math.cos(angle)))
            y = min(1.0, max(0.0, y + distance * math.sin(angle)))
        events.append(touch_event(session_id, i, i * STEP_NS, surface, x, y))
    return events


def decode_text(events: list, fuzzy: bool) -> tuple[str, float]:
    """Replay a trace; with fuzzy=False, strip alternatives (ablation)."""
    tokens = normalize_events(events)
    if not fuzzy:
        tokens = [replace(token, alternatives=()) for token in tokens]
    result = OfflineDecoder().decode(tokens)
    return result.text, result.confidence


def sweep(probes: dict, radii: list[float], seeds: int) -> list[dict]:
    """Match rate per probe and radius, fuzzy vs ablated."""
    rows = []
    for name, (keys, expected) in probes.items():
        for radius in radii:
            fuzzy_hits = ablated_hits = exact_conf = 0
            for seed in range(seeds):
                events = jitter_trace(keys, radius, seed, session_id=f"{name}-{seed}")
                text, confidence = decode_text(events, fuzzy=True)
                if text == expected:
                    fuzzy_hits += 1
                    exact_conf += confidence == 1.0
                plain, _ = decode_text(events, fuzzy=False)
                ablated_hits += plain == expected
            rows.append({
                "probe": name,
                "radius": radius,
                "seeds": seeds,
                "fuzzy_match": fuzzy_hits / seeds,
                "ablated_match": ablated_hits / seeds,
                "exact_confidence": exact_conf / seeds,
            })
    return rows


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Sweep spatial jitter vs decode")
    parser.add_argument("--seeds", type=int, default=20)
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args(argv)

    rows = sweep(PROBES, RADII, args.seeds)
    if args.json:
        print(json.dumps(rows, ensure_ascii=False, indent=2))
        return 0
    print(f"{'probe':15} {'radius':6} {'fuzzy':6} {'no-fuzzy':8} {'exact-conf':10}")
    for row in rows:
        print(f"{row['probe']:15} {row['radius']:<6.2f} "
              f"{row['fuzzy_match']:<6.2f} {row['ablated_match']:<8.2f} "
              f"{row['exact_confidence']:<10.2f}")
    print("---")
    print("fuzzy - no-fuzzy = measured rescue rate of spatial/keyboard fuzziness")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
