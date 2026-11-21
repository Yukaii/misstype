"""Build the developer-only full word bigram pilot from pinned local HPLT.

No downloads. Counts every pair, including BOS/EOS, with absolute-discount
backoff and add-one unigram smoothing. Decoding lives exclusively in Zig.
"""
import argparse
from collections import Counter
import hashlib
import json
import re
from multiprocessing import Pool
from pathlib import Path
import struct
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))
from homophone_bigram import Lex, HAN

BOS, EOS, UNK = '<s>', '</s>', '<unk>'
LATIN = '<latin>'  # an English word or number inside a Chinese clause
CLAUSE = re.compile(r'[一-鿿A-Za-z0-9 ]+')
PIECE = re.compile(r'[一-鿿]+|[A-Za-z0-9]+')
# Forms a Simplified -> Traditional converter leaves that native Traditional
# text does not use, and their native counterparts (--drop-converted).
CONVERTED = re.compile('這里|那里|哪里|心里|里面|關系|對于|終于|由于|制造|听|戰斗|眼楮|發布會|游戲')
NATIVE = re.compile('這裡|那裡|哪裡|裡面|關係|對於|終於|由於|製造|聽|戰鬥|眼睛')
CONVERTED_DOC = '<converted-doc>'  # count of skipped documents, popped before export
drop_converted = False
DISCOUNT = .75


def key(word):
    h = 0xcbf29ce484222325
    for b in word.encode():
        h = ((h ^ b) * 0x100000001b3) & ((1 << 64) - 1)
    return h


EXCLUDED = '<excluded>'  # count of skipped runs, popped before export
exclude = frozenset()


def initialize(path, excluded=(), drop=False):
    global lex, exclude, drop_converted
    lex = Lex(Path(path))
    exclude = frozenset(excluded)
    drop_converted = drop


def count_batch(texts):
    uni, pairs = Counter(), Counter()
    for text in texts:
        if drop_converted and CONVERTED.search(text):
            uni[CONVERTED_DOC] += 1  # machine-converted from Simplified (any marker): not native usage
            continue
        # A clause is Han text with English words or numbers inside it, up to
        # punctuation; each latin run is one LATIN token, so the model learns
        # what follows `check` in 幫我check一下 rather than a sentence start.
        for match in CLAUSE.finditer(text):
            pieces = PIECE.findall(match.group())
            if not any(HAN.fullmatch(p) for p in pieces):
                continue
            if any(p in exclude for p in pieces):
                uni[EXCLUDED] += 1  # an evaluation sentence verbatim: keep it out of the counts
                continue
            words = []
            for piece in pieces:
                if not HAN.fullmatch(piece):
                    if not words or words[-1] != LATIN:
                        words.append(LATIN)
                    continue
                words.extend(w if w in lex.score else UNK for w in lex.segment(piece))
            words.append(EOS)
            uni.update(words)
            pairs.update(zip([BOS] + words[:-1], words))
    return uni, pairs


def export(vocab, uni, pairs):
    vocab = set(vocab) | {BOS, EOS, UNK, LATIN}
    if BOS in uni or any(c <= 0 for c in pairs.values()) or any(c < 0 for c in uni.values()):
        raise ValueError('invalid counts')
    incoming = Counter()
    for (prev, word), count in pairs.items():
        if prev not in vocab or word not in vocab or word == BOS:
            raise ValueError('pair outside target vocabulary')
        incoming[word] += count
    if +incoming != +uni:
        raise ValueError('unigram counts differ from pair targets')
    hashes = {w: key(w) for w in vocab}
    if len(set(hashes.values())) != len(hashes):
        raise ValueError('word hash collision')
    outgoing, distinct = Counter(), Counter()
    for (prev, _), count in pairs.items():
        outgoing[prev] += count
        distinct[prev] += 1
    data = bytearray(struct.pack('<4sIIIQd', b'MWLM', 1, len(vocab), len(pairs), sum(uni.values()), DISCOUNT))
    for w in sorted(vocab, key=hashes.get):
        data.extend(struct.pack('<QIII', hashes[w], uni[w], outgoing[w], distinct[w]))
    for (prev, word), count in sorted(pairs.items(), key=lambda item: (hashes[item[0][0]], hashes[item[0][1]])):
        data.extend(struct.pack('<QQI', hashes[prev], hashes[word], count))
    return bytes(data)


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--shards', type=Path, default=Path.home() / '.cache/misstype/hplt/shards')
    p.add_argument('--lexicon', type=Path, default=Path.home() / '.cache/misstype/hplt/seglex/lexicon.tsv')
    p.add_argument('--out', type=Path, default=Path('.cache/wordlm/pilot.bin'))
    p.add_argument('--jobs', type=int, default=8)
    p.add_argument('--documents', type=int, default=10000,
                   help='documents read per shard, from the start (0 = all; the 2026-10-14 pilot used 10000)')
    p.add_argument('--extra-lexicon', type=Path, action='append', default=[],
                   help='rows (reading, text, score) appended to the pinned segmentation lexicon, e.g. '
                        'tools/place_names.py output; their hashes go into the manifest')
    p.add_argument('--drop-converted', action='store_true',
                   help='skip documents with any Simplified->Traditional conversion marker (這里, 關系, 對于, ...)')
    p.add_argument('--exclude', type=Path, action='append', default=[],
                   help='text file, one sentence per line (first TSV field): Han runs equal to one are not counted')
    args = p.parse_args()
    excluded = set()
    for path in args.exclude:
        excluded.update(line.split('\t', 1)[0].strip() for line in path.read_text(encoding='utf-8').splitlines())
    excluded.discard('')
    import pyarrow.parquet as pq
    root = Path(__file__).resolve().parent.parent
    sources = json.loads((root / 'third_party/HPLT/sources.json').read_text())
    lex_hash = hashlib.sha256(args.lexicon.read_bytes()).hexdigest()
    if lex_hash != sources['segmentation_lexicon']['sha256']:
        raise ValueError('segmentation lexicon differs from pinned HPLT build')
    extra_hashes = {}
    if args.extra_lexicon:
        # The pinned lexicon followed by reviewed extra rows (3 columns kept).
        combined = args.out.with_name(args.out.stem + '-seglex.tsv')
        combined.parent.mkdir(parents=True, exist_ok=True)
        parts = [args.lexicon.read_text(encoding='utf-8')]
        for path in args.extra_lexicon:
            extra_hashes[str(path)] = hashlib.sha256(path.read_bytes()).hexdigest()
            parts += ['\t'.join(line.split('\t')[:3]) + '\n' for line in path.read_text(encoding='utf-8').splitlines()
                      if line and not line.startswith('#')]
        combined.write_text(''.join(parts), encoding='utf-8')
        args.lexicon = combined
    unigram, pairs, provenance = Counter(), Counter(), []
    names = {}  # one string object per word: a full-shard count holds tens of millions of pairs

    def intern(word):
        return names.setdefault(word, word)

    limit = args.documents or None
    with Pool(args.jobs, initializer=initialize, initargs=(str(args.lexicon), excluded, args.drop_converted)) as pool:
        for name, expected in sources['files'].items():
            path = args.shards / Path(name).name
            digest = hashlib.file_digest(path.open('rb'), 'sha256').hexdigest()
            if digest != expected:
                raise ValueError(f'shard hash mismatch: {path}')
            texts = []
            for batch in pq.ParquetFile(path).iter_batches(batch_size=1024, columns=['text']):
                texts.extend(batch.column(0).to_pylist()[:(limit or 1 << 62) - len(texts)])
                if limit and len(texts) == limit:
                    break
            for u, b in pool.imap(count_batch, [texts[i:i+100] for i in range(0, len(texts), 100)]):
                unigram.update(u)
                for (prev, word), count in b.items():
                    pairs[(intern(prev), intern(word))] += count
            provenance.append({'file': name, 'sha256': digest, 'documents': len(texts)})
            print(f'{name}: {len(texts)} documents; {sum(unigram.values())} target tokens; '
                  f'{len(pairs)} pairs', flush=True)
    excluded_runs = unigram.pop(EXCLUDED, 0)
    converted_docs = unigram.pop(CONVERTED_DOC, 0)
    vocab = Lex(args.lexicon).score
    data = export(vocab, unigram, pairs)
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_bytes(data)
    manifest = {'version': 1, 'sources': provenance, 'lexicon_sha256': lex_hash, 'extra_lexicons': extra_hashes,
                'discount': DISCOUNT, 'unigram_smoothing': 1, 'vocabulary': len(vocab)+4, 'latin_token': LATIN,
                'target_tokens': sum(unigram.values()), 'pairs': len(pairs),
                'excluded_sentences': len(excluded), 'excluded_runs': excluded_runs,
                'drop_converted': args.drop_converted, 'converted_documents': converted_docs,
                'model_sha256': hashlib.sha256(data).hexdigest(), 'bytes': len(data)}
    args.out.with_suffix('.json').write_text(json.dumps(manifest, indent=2)+'\n')
    print(json.dumps(manifest, indent=2))


if __name__ == '__main__':
    main()
