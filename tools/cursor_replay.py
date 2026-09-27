"""Cursor-selection replay: how many picks fix the offline top-1?

Question: the pre-2026-09-27 IME cursor offered only the top path's own
word (or one syllable mid-word), so a fix that needs a different word
boundary (大|對 -> 打對) was unreachable. Does listing every word that
starts at the cursor (McBopomofo-style) reach the expected text more
often, in fewer picks?

Each synthetic sentence is typed two ways from its dictionary readings:
toned (tone key per syllable, space = first tone) and toneless (bare
symbols, one trailing space — the continuous style). The Swift binary's
`--replay` walks to the first wrong character, takes the longest matching
option, pins it, and re-decodes (see CursorReplay). Deterministic and
offline; the sentences are synthetic.

Usage:
  ./script/build_and_run.sh --build-only
  PYTHONPATH=src python tools/cursor_replay.py [--json]
"""

import argparse
import json
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "src"))
from mistype.phonetic import KEY_TO_ZHUYIN  # noqa: E402

APP_BIN = ROOT / "dist/MistypeIME.app/Contents/MacOS/MistypeIME"
ZHUYIN_TO_KEY = {symbol: key for key, symbol in KEY_TO_ZHUYIN.items()}
TONE_TO_KEY = {"": " ", "ˊ": "6", "ˇ": "3", "ˋ": "4", "˙": "7"}
MODELS = ("aligned", "startAtCursor")

SENTENCES = [
    ("測試一下會不會打對", "ㄘㄜˋ ㄕˋ ㄧ ㄒㄧㄚˋ ㄏㄨㄟˋ ㄅㄨˋ ㄏㄨㄟˋ ㄉㄚˇ ㄉㄨㄟˋ"),
    ("我今天要去買東西", "ㄨㄛˇ ㄐㄧㄣ ㄊㄧㄢ ㄧㄠˋ ㄑㄩˋ ㄇㄞˇ ㄉㄨㄥ ㄒㄧ"),
    ("這個問題很難回答", "ㄓㄜˋ ㄍㄜ˙ ㄨㄣˋ ㄊㄧˊ ㄏㄣˇ ㄋㄢˊ ㄏㄨㄟˊ ㄉㄚˊ"),
    ("明天下午開會", "ㄇㄧㄥˊ ㄊㄧㄢ ㄒㄧㄚˋ ㄨˇ ㄎㄞ ㄏㄨㄟˋ"),
    ("他說他不知道", "ㄊㄚ ㄕㄨㄛ ㄊㄚ ㄅㄨˋ ㄓ ㄉㄠˋ"),
    ("記得帶錢包", "ㄐㄧˋ ㄉㄜ˙ ㄉㄞˋ ㄑㄧㄢˊ ㄅㄠ"),
    ("回家要做作業", "ㄏㄨㄟˊ ㄐㄧㄚ ㄧㄠˋ ㄗㄨㄛˋ ㄗㄨㄛˋ ㄧㄝˋ"),
    ("語音辨識很準", "ㄩˇ ㄧㄣ ㄅㄧㄢˋ ㄕˋ ㄏㄣˇ ㄓㄨㄣˇ"),
    ("請幫我訂位", "ㄑㄧㄥˇ ㄅㄤ ㄨㄛˇ ㄉㄧㄥˋ ㄨㄟˋ"),
    ("你吃飯了嗎", "ㄋㄧˇ ㄔ ㄈㄢˋ ㄌㄜ˙ ㄇㄚ˙"),
    ("今天天氣不錯", "ㄐㄧㄣ ㄊㄧㄢ ㄊㄧㄢ ㄑㄧˋ ㄅㄨˋ ㄘㄨㄛˋ"),
    ("我們一起去看電影", "ㄨㄛˇ ㄇㄣ˙ ㄧ ㄑㄧˇ ㄑㄩˋ ㄎㄢˋ ㄉㄧㄢˋ ㄧㄥˇ"),
    ("這家店的東西很好吃", "ㄓㄜˋ ㄐㄧㄚ ㄉㄧㄢˋ ㄉㄜ˙ ㄉㄨㄥ ㄒㄧ ㄏㄣˇ ㄏㄠˇ ㄔ"),
    ("公司在市政府附近", "ㄍㄨㄥ ㄙ ㄗㄞˋ ㄕˋ ㄓㄥˋ ㄈㄨˇ ㄈㄨˋ ㄐㄧㄣˋ"),
    ("輸入法的選字體驗", "ㄕㄨ ㄖㄨˋ ㄈㄚˇ ㄉㄜ˙ ㄒㄩㄢˇ ㄗˋ ㄊㄧˇ ㄧㄢˋ"),
    ("全形符號", "ㄑㄩㄢˊ ㄒㄧㄥˊ ㄈㄨˊ ㄏㄠˋ"),
    ("他在公園散步", "ㄊㄚ ㄗㄞˋ ㄍㄨㄥ ㄩㄢˊ ㄙㄢˋ ㄅㄨˋ"),
    ("我想喝一杯咖啡", "ㄨㄛˇ ㄒㄧㄤˇ ㄏㄜ ㄧ ㄅㄟ ㄎㄚ ㄈㄟ"),
    ("這件事情很重要", "ㄓㄜˋ ㄐㄧㄢˋ ㄕˋ ㄑㄧㄥˊ ㄏㄣˇ ㄓㄨㄥˋ ㄧㄠˋ"),
    ("下雨天不打球", "ㄒㄧㄚˋ ㄩˇ ㄊㄧㄢ ㄅㄨˋ ㄉㄚˇ ㄑㄧㄡˊ"),
    ("會議記錄已經寄出", "ㄏㄨㄟˋ ㄧˋ ㄐㄧˋ ㄌㄨˋ ㄧˇ ㄐㄧㄥ ㄐㄧˋ ㄔㄨ"),
]


def split_tone(syllable: str) -> tuple[str, str]:
    if syllable and syllable[-1] in "ˊˇˋ˙":
        return syllable[:-1], syllable[-1]
    return syllable, ""


def encode(readings: str, toned: bool) -> str:
    """Dictionary readings -> physical keys. Toneless ends with one space
    (the IME converts a pending run on space)."""
    out = []
    for syllable in readings.split():
        base, tone = split_tone(syllable)
        out.append("".join(ZHUYIN_TO_KEY[symbol] for symbol in base))
        if toned:
            out.append(TONE_TO_KEY[tone])
    return "".join(out) + ("" if toned else " ")


def parse_replay(stdout: str) -> dict[str, dict[str, object]]:
    """`replay <model> picks=<n|-> ranks=<a,b>` lines -> {model: outcome}."""
    outcomes: dict[str, dict[str, object]] = {}
    top1 = ""
    for index, line in enumerate(stdout.splitlines()):
        if index == 1:
            top1 = line.split("\t")[0]
        if not line.startswith("replay "):
            continue
        _, model, picks, ranks = line.split(" ", 3)
        value = picks.removeprefix("picks=")
        rank_text = ranks.removeprefix("ranks=")
        outcomes[model] = {
            "picks": None if value == "-" else int(value),
            "ranks": [int(r) for r in rank_text.split(",") if r],
        }
    for outcome in outcomes.values():
        outcome["top1"] = top1
    return outcomes


def replay(keys: str, expected: str) -> dict[str, dict[str, object]]:
    proc = subprocess.run([str(APP_BIN), "--decode", keys, "--replay", expected],
                          capture_output=True, text=True, timeout=120, check=True)
    return parse_replay(proc.stdout)


def summarize(rows: list[dict[str, object]]) -> dict[str, dict[str, object]]:
    summary: dict[str, dict[str, object]] = {}
    for style in ("toned", "toneless"):
        subset = [row for row in rows if row["style"] == style]
        for model in MODELS:
            picks = [row[model]["picks"] for row in subset]
            reached = [p for p in picks if p is not None]
            ranks = [r for row in subset for r in row[model]["ranks"]
                     if row[model]["picks"] is not None]
            summary[f"{style}/{model}"] = {
                "cases": len(subset),
                "top1_correct": sum(p == 0 for p in picks),
                "reachable": len(reached),
                "total_picks": sum(reached),
                "max_rank": max(ranks, default=0),
            }
    return summary


def main() -> int:
    parser = argparse.ArgumentParser(description="Cursor-selection replay")
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args()
    if not APP_BIN.exists():
        print("missing build: run ./script/build_and_run.sh --build-only")
        return 2
    rows: list[dict[str, object]] = []
    for expected, readings in SENTENCES:
        for style in ("toned", "toneless"):
            outcome = replay(encode(readings, style == "toned"), expected)
            rows.append({"expected": expected, "style": style, **outcome})
    summary = summarize(rows)
    if args.json:
        print(json.dumps({"rows": rows, "summary": summary}, ensure_ascii=False, indent=2))
        return 0
    print(f"{'expected':12} {'style':9} {'top1':14} "
          f"{'aligned':>8} {'start@cur':>10}")
    for row in rows:
        cells = []
        for model in MODELS:
            picks = row[model]["picks"]
            cells.append("-" if picks is None else
                         f"{picks}" + (f" r{max(row[model]['ranks'])}" if row[model]["ranks"] else ""))
        print(f"{row['expected']:12} {row['style']:9} {row['aligned']['top1']:14} "
              f"{cells[0]:>8} {cells[1]:>10}")
    print("---  cell = picks needed (r = worst list position; '-' unreachable)")
    for key, value in summary.items():
        print(f"{key:24} top1={value['top1_correct']}/{value['cases']} "
              f"reachable={value['reachable']}/{value['cases']} "
              f"picks={value['total_picks']} max_rank={value['max_rank']}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
