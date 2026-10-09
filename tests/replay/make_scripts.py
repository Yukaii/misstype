"""Generate replay scripts for the Swift/Zig differential check.

    python3 tests/replay/make_scripts.py <out dir> [--fuzz-cases 400] [--seed 1]

Writes probes.txt (every tools/baseline/probes.tsv sentence typed toned and
toneless, then cursor, selection, marking and commit gestures) and
fuzz.txt (seeded random key sequences over every key the session handles,
under varied settings). Both use the shipping lexicon; the output is
deterministic for a seed. Synthetic text only.
"""

import argparse
import random
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SYMBOLS = list("1qaz2wsxedcrfvtgbyhnujm8ik,9ol.0p;/-") + ["5"]
TONES = ["3", "4", "6", "7", "space"]
ENGLISH = ["hello", "python", "world", "meeting", "github", "the", "computer", "zoom", "pytohn", "Python"]


def probes() -> list[tuple[str, str]]:
    rows = []
    for line in (ROOT / "tools/baseline/probes.tsv").read_text().splitlines():
        if line.startswith("#") or not line.strip():
            continue
        name, keys = line.split("\t")[:2]
        rows.append((name, keys))
    return rows


def tokens(keys: str) -> str:
    return " ".join("space" if k == " " else k for k in keys)


def probe_script() -> str:
    out = ["# Probe sentences (tools/baseline/probes.tsv) through the whole session.", "@engine shipping"]
    for name, keys in probes():
        toneless = "".join(k for k in keys if k not in "3467 ")
        out += [f"@case {name} toned", f"k {tokens(keys)}", "k left", "k left", "k tab", "k down", "k enter"]
        out += [f"@case {name} toneless", f"k {tokens(toneless)}", "k down", "k down", "k enter"]
        out += [f"@case {name} edit", f"k {tokens(keys)}", "k bs", "k bs", "k S-left", "k S-left",
                "k S-left", "k esc", "k A-left", "k right", "k esc", "k esc"]
    out += ["@case english words"]
    for word in ENGLISH:
        out += [f"t {word}", "k enter"]
    out += ["@case mixed", "k s u 3", "t python", "k c l 3", "k enter",
            "@case toggle", "k stap", "t abc", "k stap", "k s u 3", "k stap", "t ok", "k stap", "k enter"]
    return "\n".join(out) + "\n"


SETTINGS = [
    "",
    "autoshow=0 confirm=1",
    "fuzzy=0",
    "tone=0 page=5 keys=1234567890",
    "repair=3",
    "repair=1 cursor=1",
    "cursor=2 mixed=0",
    "learn=0 autocommit=6",
    "autocommit=4 page=10",
    "channel=1",
    "shift=0",
]


def fuzz_key(rng: random.Random) -> str:
    roll = rng.random()
    if roll < 0.45:
        return rng.choice(SYMBOLS)
    if roll < 0.60:
        return rng.choice(TONES)
    return rng.choice([
        "bs", "bs", "enter", "tab", "left", "right", "up", "down", "esc", "del", "pgdn", "pgup",
        "S-left", "S-right", "A-left", "A-right", "A-bs", "M-bs", "S-tab", "S-enter",
        "S-,", "S-.", "S-/", "S-1", "'", "S-'", "[", "]", "\\", "S-;", "`", "=",
        "S-a", "S-p", "stap", "rtap", "S-space", "C-c", "K-a", "other", "mod",
        "a", "s", "d", "f", "g", "h",
    ])


def fuzz_script(cases: int, seed: int) -> str:
    rng = random.Random(seed)
    out = [f"# Seeded random key sequences (seed {seed}), shipping lexicon."]
    per_engine = max(1, cases // len(SETTINGS))
    for index in range(cases):
        if index % per_engine == 0:
            setting = SETTINGS[(index // per_engine) % len(SETTINGS)]
            out.append("@engine shipping")
            if setting:
                out.append(f"@set {setting}")
        out.append(f"@case fuzz {index}")
        for _ in range(rng.randint(4, 40)):
            roll = rng.random()
            if roll < 0.04:
                out.append(f"pick {rng.randint(0, 9)}")
            elif roll < 0.06:
                out.append("commit")
            elif roll < 0.08:
                out.append("t " + rng.choice(ENGLISH))
            else:
                out.append("k " + fuzz_key(rng))
        out.append("k enter")
    return "\n".join(out) + "\n"


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("out", type=Path)
    parser.add_argument("--fuzz-cases", type=int, default=400)
    parser.add_argument("--seed", type=int, default=1)
    args = parser.parse_args()
    args.out.mkdir(parents=True, exist_ok=True)
    (args.out / "probes.txt").write_text(probe_script())
    (args.out / "fuzz.txt").write_text(fuzz_script(args.fuzz_cases, args.seed))


if __name__ == "__main__":
    main()
