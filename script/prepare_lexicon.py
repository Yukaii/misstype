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
            entries[(reading, text)] = math.log((count + 1) / total)
    output = cache / 'lexicon.tsv'
    output.write_text(''.join(f'{reading}\t{text}\t{score:.6f}\n'
                             for (reading, text), score in sorted(entries.items())))
    print(f'Prepared {len(entries):,} lexicon entries: {output}')


if __name__ == '__main__':
    main()
