"""Synthesize jittered touch taps to find where fuzziness stops helping.

Usage:
    python3 tools/noise.py [--seeds 20] [--json]

For each probe phrase, tap every key centre with uniform-disk jitter of
radius r (normalized units, seeded, clamped to the surface) and decode the
taps with the Zig touch decoder (`misstype-dev --touch-batch`) three ways:

  touch     spatial hypotheses + keyboard repair (what a touch surface gets)
  keyboard  nearest key only, keyboard repair on (a conventional keyboard)
  exact     nearest key only, no repair (ablation)

touch - keyboard is the measured benefit of coordinate-aware decoding,
keyboard - exact what edit repair alone rescues. Needs a built
misstype-dev (`cd core-zig && zig build`). Offline only; exits 0 (report,
not gate).
"""

import argparse
import json
import math
import random
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import misstype_dev as dev  # noqa: E402

# (display name, physical key taps with tones, expected text). Toned taps
# keep the tone-optional fallback out of the picture, so the sweep isolates
# spatial error plus fuzzy rescue.
PROBES = {
    "ni-hao": (["s", "u", "3", "c", "l", "3"], "你好"),
    "zao-shang-hao": (["y", "l", "3", "g", ";", "4", "c", "l", "3"], "早上好"),
}

RADII = [0.0, 0.02, 0.05, 0.08, 0.10, 0.12, 0.15, 0.20]


MODES = {
    "touch": (),
    "keyboard": ("--no-spatial",),
    "exact": ("--no-spatial", "--no-fuzzy"),
}


def jitter_trace(keys: list[str], radius: float, seed: int) -> list[tuple[str, float, float]]:
    """Tap key centres with seeded uniform-disk jitter; radius 0 is exact."""
    _, layout = dev.touch_layout()
    rng = random.Random(seed)
    taps = []
    for key in keys:
        surface, x, y = layout[key]
        if radius > 0:
            angle = rng.uniform(0, 2 * math.pi)
            distance = radius * math.sqrt(rng.random())
            x = min(1.0, max(0.0, x + distance * math.cos(angle)))
            y = min(1.0, max(0.0, y + distance * math.sin(angle)))
        taps.append((surface, x, y))
    return taps


def sweep(probes: dict, radii: list[float], seeds: int) -> list[dict]:
    """Match rate per probe and radius for each decoding mode."""
    cells = [(name, radius, seed) for name in probes for radius in radii for seed in range(seeds)]
    taps = [jitter_trace(probes[name][0], radius, seed) for name, radius, seed in cells]
    hits: dict[tuple[str, float], dict[str, int]] = {}
    for mode, flags in MODES.items():
        answers = dev.touch_batch(taps, *flags)
        for (name, radius, _), answer in zip(cells, answers):
            top = answer[0][0] if answer else ""
            counts = hits.setdefault((name, radius), dict.fromkeys(MODES, 0))
            counts[mode] += top == probes[name][1]
    return [{"probe": name, "radius": radius, "seeds": seeds,
             **{mode: n / seeds for mode, n in counts.items()}}
            for (name, radius), counts in hits.items()]


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Sweep spatial jitter vs decode")
    parser.add_argument("--seeds", type=int, default=20)
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args(argv)

    rows = sweep(PROBES, RADII, args.seeds)
    if args.json:
        print(json.dumps(rows, ensure_ascii=False, indent=2))
        return 0
    print(f"{'probe':15} {'radius':6} {'touch':6} {'keyboard':8} {'exact':6}")
    for row in rows:
        print(f"{row['probe']:15} {row['radius']:<6.2f} "
              f"{row['touch']:<6.2f} {row['keyboard']:<8.2f} {row['exact']:<6.2f}")
    print("---")
    print("touch - keyboard = benefit of coordinate-aware decoding over a keyboard")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
