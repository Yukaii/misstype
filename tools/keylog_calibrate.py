"""Estimate typist parameters from a local key log (codes only, no text).

Question: tools/typing_eval.py's personas (error rate, how often an error is
noticed, tone habit, error-type mix) are assumptions. What do real key logs
say? This reads the macOS IME debug log's key trace (`key=<macOS keycode>
flags= [en= latin=] comp= ...`, written until 2026-10-09; see
docs/development.md) and reports what can be measured from keys alone:

  - keystrokes in Zhuyin mode, syllables (slot-order segmentation), and the
    share of syllables closed by a tone key (Space counts as first tone)
  - noticed errors: a run of Backspaces followed by retyped keys is aligned
    against the keys it deleted and classified as substitution (neighbour
    key or not), transposition, omission, insertion, tone change or rewrite
  - candidate interaction: Down/arrow picks per composition, Escape aborts

What it cannot see: errors the typist never noticed (the IME repaired or
committed them). Those need the intended text, which the log does not hold,
so the noticed rate is a lower bound on the true error rate.

The log and every output are personal data: keep them under .cache/ and
never commit them. The test fixture is synthetic.

Usage:
  python3 tools/keylog_calibrate.py .cache/keylog/MisstypeIME-debug.log
  python3 tools/keylog_calibrate.py LOG --json .cache/keylog/calibration.json
"""

import argparse
import json
import re
import sys
from collections import Counter
from pathlib import Path

# macOS virtual keycodes (ANSI layout) -> trace labels used by misstype-dev.
KEYCODES = {
    0: "a", 1: "s", 2: "d", 3: "f", 4: "h", 5: "g", 6: "z", 7: "x", 8: "c", 9: "v",
    11: "b", 12: "q", 13: "w", 14: "e", 15: "r", 16: "y", 17: "t", 18: "1", 19: "2",
    20: "3", 21: "4", 22: "6", 23: "5", 24: "=", 25: "9", 26: "7", 27: "-", 28: "8",
    29: "0", 30: "]", 31: "o", 32: "u", 33: "[", 34: "i", 35: "p", 37: "l", 38: "j",
    39: "'", 40: "k", 41: ";", 42: "\\", 43: ",", 44: "/", 45: "n", 46: "m", 47: ".",
    50: "`",
    36: "⏎", 48: "⇥", 49: " ", 51: "⌫", 53: "⎋", 117: "⌦",
    123: "←", 124: "→", 125: "↓", 126: "↑",
}
TONES = set("3467 ")
# Standard Zhuyin layout key -> slot (0 initial, 1 medial, 2 final).
INITIALS = set("1qaz2wsxedcrfv5tgbyhn")
MEDIALS = set("ujm")
FINALS = set("8ik,9ol.0p;/-")
ROWS = ["1234567890-", "qwertyuiop", "asdfghjkl;", "zxcvbnm,./"]
POS = {ch: (r, c) for r, row in enumerate(ROWS) for c, ch in enumerate(row)}
LINE = re.compile(r"^(?P<ts>[\d.]+) key=(?P<code>-?\d+) flags=(?P<flags>\d+)"
                  r"(?: en=(?P<en>\d) latin=(?P<latin>\d))? comp=(?P<comp>\d)")
# NSEvent.ModifierFlags: shift 1<<17, control 1<<18, option 1<<19, command 1<<20.
CHORD = (1 << 18) | (1 << 19) | (1 << 20)


def neighbours(a: str, b: str) -> bool:
    if a not in POS or b not in POS or a == b:
        return False
    (r1, c1), (r2, c2) = POS[a], POS[b]
    return abs(r1 - r2) <= 1 and abs(c1 - c2) <= 1


def slot(key: str) -> int | None:
    if key in INITIALS:
        return 0
    if key in MEDIALS:
        return 1
    if key in FINALS:
        return 2
    return None


def syllables(keys: list[str]) -> tuple[int, int]:
    """(syllables, closed by a tone key) by Zhuyin slot order."""
    count = toned = 0
    last = -1
    open_ = False
    for k in keys:
        if k in TONES and open_:
            toned += 1
            open_, last = False, -1
            continue
        s = slot(k)
        if s is None:
            continue
        if not open_ or s <= last:
            count += 1
            open_ = True
        last = s
    return count, toned


def classify(deleted: list[str], retyped: list[str]) -> str:
    """What kind of slip a Backspace-and-retype fixed."""
    if deleted == retyped:
        return "unchanged"
    if len(deleted) == len(retyped):
        diffs = [i for i, (a, b) in enumerate(zip(deleted, retyped)) if a != b]
        if len(diffs) == 1:
            a, b = deleted[diffs[0]], retyped[diffs[0]]
            if a in TONES and b in TONES:
                return "tone"
            return "substitution-neighbour" if neighbours(a, b) else "substitution-far"
        if len(diffs) == 2 and diffs[1] == diffs[0] + 1 and \
                deleted[diffs[0]] == retyped[diffs[1]] and deleted[diffs[1]] == retyped[diffs[0]]:
            return "transposition"
    if len(retyped) == len(deleted) + 1:
        for i in range(len(retyped)):
            if retyped[:i] + retyped[i + 1:] == deleted:
                return "omission"  # the typist had left a key out
    if len(deleted) == len(retyped) + 1:
        for i in range(len(deleted)):
            if deleted[:i] + deleted[i + 1:] == retyped:
                return "insertion"  # the typist had an extra key
    return "rewrite"


def compositions(lines):
    """Zhuyin-mode key runs, split where the composition was empty before a key."""
    current: list[str] = []
    for line in lines:
        m = LINE.match(line)
        if not m:
            continue
        if m["en"] == "1" or m["latin"] == "1" or int(m["flags"]) & CHORD:
            continue
        label = KEYCODES.get(int(m["code"]))
        if label is None:
            continue
        if m["comp"] == "0" and current:
            yield current
            current = []
        if m["comp"] == "0" and label not in POS and label != " ":
            continue  # navigation or Return outside a composition
        current.append(label)
    if current:
        yield current


def analyse(keys: list[str], stats: Counter, kinds: Counter) -> None:
    typed: list[str] = []  # keys currently standing in the composition
    i = 0
    while i < len(keys):
        k = keys[i]
        if k == "⌫":
            run = 0
            while i < len(keys) and keys[i] == "⌫":
                run += 1
                i += 1
            stats["backspace_runs"] += 1
            stats["backspaces"] += run
            deleted = typed[-run:] if run <= len(typed) else []
            del typed[max(0, len(typed) - run):]
            retyped = []
            j = i
            while j < len(keys) and len(retyped) < len(deleted) + 1 and (keys[j] in POS or keys[j] == " "):
                retyped.append(keys[j])
                j += 1
            if deleted and retyped:
                # Retyping may run on into new text; keep the best-matching prefix.
                best = min((classify(deleted, retyped[:n]) for n in range(max(1, len(deleted) - 1), len(retyped) + 1)),
                           key=lambda kind: ["unchanged", "tone", "substitution-neighbour", "transposition",
                                             "omission", "insertion", "substitution-far", "rewrite"].index(kind))
                kinds[best] += 1
            continue
        if k in POS or k == " ":
            typed.append(k)
            stats["keys"] += 1
        elif k == "↓":
            stats["picks"] += 1
        elif k == "⎋":
            stats["escapes"] += 1
        elif k in "←→":
            stats["cursor_moves"] += 1
        i += 1
    count, toned = syllables(typed)
    stats["syllables"] += count
    stats["toned_syllables"] += toned
    stats["compositions"] += 1


def calibrate(lines) -> dict:
    stats: Counter = Counter()
    kinds: Counter = Counter()
    for keys in compositions(lines):
        analyse(keys, stats, kinds)
    slips = sum(v for k, v in kinds.items() if k not in ("unchanged", "rewrite"))
    keys = max(stats["keys"], 1)
    return {
        "keys": stats["keys"], "compositions": stats["compositions"], "syllables": stats["syllables"],
        "tone_rate": round(stats["toned_syllables"] / max(stats["syllables"], 1), 3),
        "backspace_per_100_keys": round(100 * stats["backspaces"] / keys, 2),
        "noticed_slip_rate": round(slips / keys, 4),
        "noticed_mix": {k: round(v / max(slips, 1), 3) for k, v in sorted(kinds.items())
                        if k not in ("unchanged", "rewrite")},
        "fix_kinds": dict(sorted(kinds.items())),
        "picks_per_composition": round(stats["picks"] / max(stats["compositions"], 1), 3),
        "escapes": stats["escapes"], "cursor_moves": stats["cursor_moves"],
        "limits": "noticed slips only (a lower bound); unnoticed errors need the intended text",
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("logs", type=Path, nargs="+")
    parser.add_argument("--json", type=Path, help="write the summary here (keep it under .cache/)")
    args = parser.parse_args()
    lines = []
    for path in args.logs:
        lines += path.read_text(encoding="utf-8", errors="replace").splitlines()
    result = calibrate(lines)
    if result["keys"] == 0:
        print("no Zhuyin key events found (key logging stopped on 2026-10-09)", file=sys.stderr)
        return 1
    print(json.dumps(result, ensure_ascii=False, indent=1))
    if args.json:
        args.json.parent.mkdir(parents=True, exist_ok=True)
        args.json.write_text(json.dumps(result, ensure_ascii=False, indent=1))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
