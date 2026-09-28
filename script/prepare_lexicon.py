"""Build the native IME lexicon from pinned, checksum-verified source data.

Sources: McBopomofo (third_party/McBopomofo/sources.json) for readings and
scores; NAER 通用詞頻表 (third_party/NAER/sources.json) only to order single
chars for toneless input (toneless.tsv). Only build-time public dictionary
downloads; never uploads user input.
This is a Mistype frequency baseline, not McBopomofo's full LM compiler.
"""
import argparse
import hashlib
import json
import math
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


HETEROPHONE_STEP = 0.693147 * math.log(10)
HETEROPHONE_FLOOR = -6.8 * math.log(10)


def heterophone_score(score, rank):
    """Score of one reading of a heterophonic char (rank None = unlisted)."""
    if rank == 1:
        return score
    if rank is None:
        return HETEROPHONE_FLOOR
    return max(score - HETEROPHONE_STEP * (rank - 1), HETEROPHONE_FLOOR)


def apply_reading_order(entries, path):
    """Hand-reviewed single-syllable order: swap scores so `preferred`
    takes `displaced`'s place for that reading. Stale rows fail loudly."""
    if not path.exists():
        return
    for line in path.read_text(encoding='utf-8').splitlines():
        if not line or line.startswith('#'):
            continue
        reading, preferred, displaced = line.split('\t')
        a, b = (reading, preferred), (reading, displaced)
        if a not in entries or b not in entries:
            raise ValueError(f'reading_order.tsv row not in lexicon: {line!r}')
        if entries[a] < entries[b]:
            entries[a], entries[b] = entries[b], entries[a]


def fetch_pinned(manifest_path, cache):
    """Download (once) and checksum-verify every file of a pinned manifest;
    returns the last file's cached path."""
    manifest = json.loads(manifest_path.read_text())
    repository = manifest['repository'].removeprefix('https://github.com/')
    cache.mkdir(parents=True, exist_ok=True)
    target = None
    for path, digest in manifest['files'].items():
        target = cache / Path(path).name
        if not target.exists():
            url = f"https://raw.githubusercontent.com/{repository}/{manifest['commit']}/{path}"
            data = urllib.request.urlopen(url, timeout=60).read()
            if hashlib.sha256(data).hexdigest() != digest:
                raise ValueError(f'checksum mismatch: {path}')
            target.write_bytes(data)
        if hashlib.sha256(target.read_bytes()).hexdigest() != digest:
            raise ValueError(f'cached checksum mismatch: {path}')
    return target


def load_word_frequency(path):
    """`word<TAB>per_million` (NAER 通用詞頻表 subset) -> probability."""
    table = {}
    for line in path.read_text(encoding='utf-8').splitlines():
        fields = line.split('\t')
        if len(fields) == 2 and not line.startswith('#'):
            try:
                table[fields[0]] = float(fields[1]) / 1e6
            except ValueError:
                continue
    return table


def toneless_base(reading):
    return ''.join(c for c in reading if c not in 'ˊˇˋ˙')


def toneless_order(entries, general, ranked):
    """Toneless-input scores for single chars. Chars sharing a toneless
    base (ㄔ/ㄔˊ/ㄔˇ/ㄔˋ) trade score slots by standalone frequency: the
    group's score multiset is unchanged (word/char balance and repair costs
    keep their scale), only who holds which slot moves. Toneless input
    compares across tones, where McBopomofo's char counts (bound morphemes
    included: 持 via 支持) beat standalone use (吃). Secondary heterophone
    readings and chars missing from the table keep their scores. Returns
    only the changed (reading, text) -> score; `entries` is not touched, so
    toned input keeps the corpus order."""
    groups = {}
    for (reading, text), score in entries.items():
        if len(text) != 1 or '-' in reading or text not in general:
            continue
        rank = ranked.get(text, {}).get(reading, 1 if text not in ranked else None)
        if rank != 1:
            continue
        groups.setdefault(toneless_base(reading), []).append((reading, text))
    changed = {}
    for keys in groups.values():
        if len(keys) < 2:
            continue
        scores = sorted((entries[key] for key in keys), reverse=True)
        order = sorted(keys, key=lambda key: (-general[key[1]], -entries[key]))
        for key, score in zip(order, scores):
            if entries[key] != score:
                changed[key] = score
    return changed


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--word-frequency', type=Path,
                        help='word<TAB>per_million table (default: pinned NAER subset)')
    parser.add_argument('--out', type=Path, help='lexicon.tsv path (toneless.tsv beside it)')
    args = parser.parse_args()
    cache = ROOT / '.cache/mcbopomofo'
    fetch_pinned(ROOT / 'third_party/McBopomofo/sources.json', cache)

    counts = {}
    for line in (cache / 'phrase.occ').read_text().splitlines():
        fields = line.split()
        if len(fields) == 2:
            counts[fields[0]] = float(fields[1])
    total = sum(counts.values()) + len(counts)
    # Heterophones (破音字): McBopomofo's cook.py gives a single char's full
    # frequency only to its heterophony1 reading; heterophony2/3 readings
    # drop 0.693 per rank, anything else sits at the floor. Its values are
    # log10, so in our natural-log units the step is 0.693*ln(10) and the
    # floor -6.8*ln(10). Without this every reading of 暫 (ㄓㄢˋ, and the
    # variant ㄗㄢˋ) carried the char's whole count and 暫 beat 讚 for ㄗㄢˋ.
    ranked = {}
    for rank in (1, 2, 3):
        for line in (cache / f'heterophony{rank}.list').read_text().splitlines():
            fields = line.split()
            if len(fields) == 2 and not line.startswith('#'):
                ranked.setdefault(fields[0], {})[fields[1]] = rank
    entries = {}
    for filename in ('BPMFBase.txt', 'BPMFMappings.txt'):
        for line in (cache / filename).read_text().splitlines():
            fields = line.split()
            if len(fields) < 2 or line.startswith('#'):
                continue
            text = fields[0]
            readings = fields[1:2] if filename == 'BPMFBase.txt' else fields[1:]
            if not all(all('\u3105' <= c <= '\u3129' or c in 'ˊˇˋ˙' for c in r) for r in readings):
                continue
            if not 1 <= len(readings) <= 8 or len(text) != len(readings):
                continue
            # Skip standalone Bopomofo, punctuation and uncommon zero-count
            # variants. This native trial uses the corpus's observed vocabulary.
            count = counts.get(text, 0)
            if count <= 0 or all('\u3105' <= c <= '\u3129' for c in text):
                continue
            reading = '-'.join(r.replace('˙', '') + '˙' if '˙' in r else r for r in readings)
            score = math.log((count + 1) / total)
            if len(text) == 1 and text in ranked:
                score = heterophone_score(score, ranked[text].get(readings[0]))
            entries[(reading, text)] = score
    apply_reading_order(entries, ROOT / 'Resources/reading_order.tsv')
    general = load_word_frequency(args.word_frequency or fetch_pinned(
        ROOT / 'third_party/NAER/sources.json', ROOT / '.cache/naer'))
    toneless = toneless_order(entries, general, ranked)
    toneless_path = (args.out or cache / 'lexicon.tsv').with_name('toneless.tsv')
    toneless_path.write_text(''.join(f'{reading}\t{text}\t{score:.6f}\n'
                                     for (reading, text), score in sorted(toneless.items())))
    print(f'Prepared {len(toneless):,} toneless overrides: {toneless_path}')
    output = args.out or cache / 'lexicon.tsv'
    output.write_text(''.join(f'{reading}\t{text}\t{score:.6f}\n'
                             for (reading, text), score in sorted(entries.items())))
    print(f'Prepared {len(entries):,} lexicon entries: {output}')


if __name__ == '__main__':
    main()
