"""Export a ChiaKey Lexicon release DB into Mistype's measurement formats.

Writes (local cache only, never committed — the release DB bundles
CC BY-NC data):
  lexicon.tsv   reading-with-dashes <TAB> text <TAB> score * scale
  bigrams.tsv   previous <TAB> current <TAB> bonus * scale
where bonus = calibrated bigram score - unigram(current, same reading),
kept only when positive (ChiaKey's weak rows sit below the unigram
baseline and stay inert).

qstrings are KeyKey absolute-order pairs (2 bytes per syllable); the
decoder mirrors ChiaKey-Lexicon src/phonetics.rs bpmf_for_qstring.

Usage:
  gh release download <tag> -R chiakich/ChiaKey-Lexicon \\
      -p 'ChiaKeySource-*.db' -O ~/.cache/mistype/chiakey/ChiaKeySource.db
  python tools/chiakey_export.py [--scale 1] [--out ~/.cache/mistype/chiakey/x1]
"""

import argparse
import sqlite3
from pathlib import Path

CACHE = Path.home() / ".cache/mistype/chiakey"
CONSONANTS = "ㄅㄆㄇㄈㄉㄊㄋㄌㄍㄎㄏㄐㄑㄒㄓㄔㄕㄖㄗㄘㄙ"
MEDIALS = "ㄧㄨㄩ"
VOWELS = "ㄚㄛㄜㄝㄞㄟㄠㄡㄢㄣㄤㄥㄦ"
TONES = ["", "ˊ", "ˇ", "ˋ", "˙"]


def syllable(order: int) -> str | None:
    tone, rest = divmod(order, 22 * 4 * 14)
    vowel, rest = divmod(rest, 22 * 4)
    medial, consonant = divmod(rest, 22)
    if tone >= len(TONES) or consonant > len(CONSONANTS) or vowel > len(VOWELS):
        return None
    text = ((CONSONANTS[consonant - 1] if consonant else "")
            + (MEDIALS[medial - 1] if medial else "")
            + (VOWELS[vowel - 1] if vowel else ""))
    return text + TONES[tone] if text else None


def readings(qstring: str) -> list[str] | None:
    if not qstring or len(qstring) % 2:
        return None
    out = []
    for first, second in zip(qstring[::2], qstring[1::2]):
        a, b = ord(first) - 48, ord(second) - 48
        if a < 0 or b < 0 or a >= 79:
            return None
        text = syllable(a + b * 79)
        if text is None:
            return None
        out.append(text)
    return out


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--db", type=Path, default=CACHE / "ChiaKeySource.db")
    parser.add_argument("--scale", type=float, default=1.0)
    parser.add_argument("--out", type=Path, default=None)
    args = parser.parse_args()
    out = args.out or CACHE / f"x{args.scale:g}"
    out.mkdir(parents=True, exist_ok=True)
    db = sqlite3.connect(args.db)

    unigram: dict[tuple[str, str], float] = {}
    rows = 0
    with (out / "lexicon.tsv").open("w", encoding="utf-8") as handle:
        for qstring, text, score in db.execute(
                "select qstring, current, probability from unigrams"):
            parts = readings(qstring)
            if not parts or len(parts) > 8 or score < -20 or len(text) != len(parts):
                continue
            unigram[(qstring, text)] = score
            handle.write(f"{'-'.join(parts)}\t{text}\t{score * args.scale:.6f}\n")
            rows += 1

    bigrams = 0
    with (out / "bigrams.tsv").open("w", encoding="utf-8") as handle:
        for qstring, previous, current, stored in db.execute(
                "select qstring, previous, current, probability from bigrams"):
            if not previous or not current or " " not in qstring:
                continue
            base = unigram.get((qstring.split(" ", 1)[1], current))
            if base is None or stored <= base:
                continue
            handle.write(f"{previous}\t{current}\t{(stored - base) * args.scale:.6f}\n")
            bigrams += 1
    print(f"{out}: unigrams={rows} bigram_bonuses={bigrams}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
