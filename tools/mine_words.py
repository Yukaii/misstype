"""Mine two-character words the dictionary lacks from full word-pair counts.

Question: how many first-choice misses are words the dictionary does not
have (熊讚, 多益, 神獸, 孫輩)? The word model's corpus was segmented with the
dictionary, so such a word appears there as a frequent, tightly bound pair
of single-character words. This reads a full MWLM model (tools/word_lm.py
output, hashes only), resolves hashes through the segmentation lexicon, and
keeps pairs of single Han characters with

  count(a, b)              >= --min-count
  PMI = ln(c(a,b) N / (c(a) c(b)))   >= --min-pmi
  max(share of a's uses followed by b, share of b's uses after a) >= --min-share
  (a common character such as 多 or 小 cannot carry the bound alone)

Readings come from the characters' own entries in --lexicon (a polyphone
takes its best-scored reading; candidates with several readings for a char
are marked so a person can check them). Scores are put on the dictionary's
scale by a least-squares fit of existing two-character words' dictionary
scores against ln(corpus frequency).

Output is a TSV in lexicon shape (reading, text, score) plus count, PMI and
a `polyphone` flag. It is derived from HPLT web text (see
third_party/HPLT/); keep generated lists under .cache/ until reviewed.

Usage:
  python3 tools/mine_words.py --model .cache/wordlm/v4/all-clean.bin \\
      --lexicon dist/MisstypeIME.app/Contents/Resources/lexicon.tsv \\
      --out .cache/wordlm/mined.tsv
"""
import argparse
import math
import mmap
import struct
import sys
from collections import defaultdict
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from word_lm import key  # noqa: E402


def is_han(text: str) -> bool:
    return all('一' <= c <= '鿿' for c in text)


def load_lexicon(paths):
    """text -> list of (reading, score)."""
    entries = defaultdict(list)
    for path in paths:
        for line in Path(path).read_text(encoding='utf-8').splitlines():
            if not line or line.startswith('#'):
                continue
            fields = line.split('\t')
            if len(fields) < 3:
                continue
            try:
                entries[fields[1]].append((fields[0], float(fields[2])))
            except ValueError:
                continue
    return entries


def fit(points):
    """Least squares y = a x + b."""
    n = len(points)
    sx = sum(x for x, _ in points)
    sy = sum(y for _, y in points)
    sxx = sum(x * x for x, _ in points)
    sxy = sum(x * y for x, y in points)
    a = (n * sxy - sx * sy) / (n * sxx - sx * sx)
    return a, (sy - a * sx) / n


def mine(model: Path, lexicon: dict, min_count: int, min_pmi: float, min_share: float):
    with model.open('rb') as fh, mmap.mmap(fh.fileno(), 0, access=mmap.ACCESS_READ) as data:
        magic, version, n, m, tokens, _ = struct.unpack_from('<4sIIIQd', data)
        if (magic, version) != (b'MWLM', 1) or len(data) != 32 + (n + m) * 20:
            raise ValueError('not a full MWLM v1 model')
        unigram, outgoing = {}, {}
        for i in range(n):
            h, u, o, _ = struct.unpack_from('<QIII', data, 32 + i * 20)
            unigram[h], outgoing[h] = u, o
        single = {key(t): t for t in lexicon if len(t) == 1 and is_han(t)}
        found = []
        for h, w, c in struct.iter_unpack('<QQI', memoryview(data)[32 + n * 20:]):
            if c >= min_count and h in single and w in single:
                found.append((single[h], single[w], c, h, w))
        # c(b) as a target is its unigram count; c(a) as a history is outgoing.
        calibration = []
        for text, rows in lexicon.items():
            if len(text) == 2 and is_han(text):
                u = unigram.get(key(text), 0)
                if u >= 3:
                    calibration.append((math.log(u / tokens), max(s for _, s in rows)))
    a, b = fit(calibration)
    out = []
    for x, y, c, h, w in found:
        text = x + y
        if text in lexicon:
            continue
        pmi = math.log(c * tokens / (outgoing[h] * unigram[w]))
        share = max(c / outgoing[h], c / unigram[w])
        if pmi < min_pmi or share < min_share:
            continue
        rx, ry = lexicon[x], lexicon[y]
        reading = max(rx, key=lambda r: r[1])[0] + '-' + max(ry, key=lambda r: r[1])[0]
        polyphone = len({r for r, _ in rx}) > 1 or len({r for r, _ in ry}) > 1
        out.append((reading, text, round(a * math.log(c / tokens) + b, 3), c, round(pmi, 2), polyphone))
    out.sort(key=lambda row: -row[3])
    return out, (a, b, len(calibration))


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument('--model', type=Path, required=True)
    p.add_argument('--lexicon', type=Path, action='append', required=True)
    p.add_argument('--min-count', type=int, default=50)
    p.add_argument('--min-pmi', type=float, default=4.0)
    p.add_argument('--min-share', type=float, default=0.1)
    p.add_argument('--out', type=Path, required=True)
    args = p.parse_args()
    lexicon = load_lexicon(args.lexicon)
    rows, (a, b, k) = mine(args.model, lexicon, args.min_count, args.min_pmi, args.min_share)
    args.out.parent.mkdir(parents=True, exist_ok=True)
    with args.out.open('w', encoding='utf-8') as fh:
        fh.write(f'# mined by tools/mine_words.py from {args.model.name}; score = {a:.3f} ln(freq) + {b:.3f} '
                 f'(fit on {k} two-character words); columns: reading text score count pmi polyphone\n')
        for row in rows:
            fh.write('\t'.join(map(str, row)) + '\n')
    print(f'{len(rows)} candidates -> {args.out} (score = {a:.3f} ln(freq) + {b:.3f}, fit on {k} words)')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
