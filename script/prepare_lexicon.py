"""Build the native IME lexicon from pinned, checksum-verified source data.

Only build-time public dictionary downloads; never uploads user input.
This is a Mistype frequency baseline, not McBopomofo's full LM compiler.
"""
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


def main():
    manifest = json.loads((ROOT / 'third_party/McBopomofo/sources.json').read_text())
    cache = ROOT / '.cache/mcbopomofo'
    cache.mkdir(parents=True, exist_ok=True)
    for path, digest in manifest['files'].items():
        target = cache / Path(path).name
        if not target.exists():
            url = f"https://raw.githubusercontent.com/openvanilla/McBopomofo/{manifest['commit']}/{path}"
            data = urllib.request.urlopen(url, timeout=60).read()
            if hashlib.sha256(data).hexdigest() != digest:
                raise ValueError(f'checksum mismatch: {path}')
            target.write_bytes(data)
        if hashlib.sha256(target.read_bytes()).hexdigest() != digest:
            raise ValueError(f'cached checksum mismatch: {path}')

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
    output = cache / 'lexicon.tsv'
    output.write_text(''.join(f'{reading}\t{text}\t{score:.6f}\n'
                             for (reading, text), score in sorted(entries.items())))
    print(f'Prepared {len(entries):,} lexicon entries: {output}')


if __name__ == '__main__':
    main()
