"""Live-conversion stability: what does the preview do while you type?

Question (user report 2026-09-27): with live conversion, characters that
were already converted fall back to Bopomofo mid-sentence, and partial
syllables snap to a character immediately, so the preview jumps around.
This replays each synthetic sentence key by key through the Swift
binary's `--live-trace` (the exact IME preview path, `livePreview`) and
counts, between consecutive keystrokes:

- revert: a position showing a Han character now shows Bopomofo;
- churn:  a settled Han character (not the last converted one, which is
  the syllable being typed) changes to another Han character.

Offline and deterministic; sentences are the synthetic cursor_replay sets.

Usage:
  ./script/build_and_run.sh --build-only
  PYTHONPATH=src python tools/live_trace.py [--set dev|holdout|all] [--show N]
"""

import argparse
import json
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from cursor_replay import APP_BIN, encode, sentence_set  # noqa: E402


def is_han(char: str) -> bool:
    return "㐀" <= char <= "鿿"


def is_bopomofo(char: str) -> bool:
    return "ㄅ" <= char <= "ㄯ"


def trace(keys: str) -> list[str]:
    proc = subprocess.run([str(APP_BIN), "--decode", keys, "--live-trace"],
                          capture_output=True, text=True, timeout=120, check=True)
    return [line.split("\t", 2)[2] if line.count("\t") >= 2 else ""
            for line in proc.stdout.splitlines() if line.startswith("live\t")]


def stability(previews: list[str]) -> dict[str, int]:
    """Count revert/churn events (steps) and characters between steps."""
    reverts = revert_chars = churns = churn_chars = 0
    for before, after in zip(previews, previews[1:]):
        converted = 0
        while converted < len(before) and is_han(before[converted]):
            converted += 1
        reverted = sum(1 for j in range(min(len(before), len(after)))
                       if is_han(before[j]) and is_bopomofo(after[j]))
        churned = sum(1 for j in range(min(converted - 1, len(after)))
                      if is_han(after[j]) and after[j] != before[j])
        reverts += reverted > 0
        revert_chars += reverted
        churns += churned > 0
        churn_chars += churned
    return {"steps": max(len(previews) - 1, 0), "revert_steps": reverts,
            "revert_chars": revert_chars, "churn_steps": churns, "churn_chars": churn_chars}


def main() -> int:
    parser = argparse.ArgumentParser(description="Live-conversion stability replay")
    parser.add_argument("--set", choices=["seed", "dev", "holdout", "all"], default="dev")
    parser.add_argument("--show", type=int, default=0,
                        help="print the per-keystroke preview for the N worst sentences")
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args()
    if not APP_BIN.exists():
        print("missing build: run ./script/build_and_run.sh --build-only")
        return 2
    rows = []
    for expected, readings in sentence_set(args.set):
        for style in ("toned", "toneless"):
            previews = trace(encode(readings, style == "toned"))
            rows.append({"expected": expected, "style": style, "final": previews[-1] if previews else "",
                         "previews": previews, **stability(previews)})
    summary: dict[str, dict[str, int]] = {}
    for style in ("toned", "toneless"):
        subset = [r for r in rows if r["style"] == style]
        summary[style] = {key: sum(r[key] for r in subset)
                          for key in ("steps", "revert_steps", "revert_chars", "churn_steps", "churn_chars")}
        summary[style]["sentences"] = len(subset)
        summary[style]["final_ok"] = sum(r["final"] == r["expected"] for r in subset)
    if args.json:
        print(json.dumps({"summary": summary, "rows": rows}, ensure_ascii=False, indent=2))
        return 0
    for style, values in summary.items():
        print(f"{style:9} " + " ".join(f"{k}={v}" for k, v in values.items()))
    worst = sorted(rows, key=lambda r: (r["revert_steps"] + r["churn_steps"]), reverse=True)
    for row in worst[:args.show]:
        print(f"--- {row['style']} {row['expected']} revert={row['revert_steps']} churn={row['churn_steps']}")
        for step, text in enumerate(row["previews"], 1):
            print(f"  {step:3} {text}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
