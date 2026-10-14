"""Build the developer-only full word bigram pilot from pinned local HPLT.

No downloads. Counts every pair, including BOS/EOS, with absolute-discount
backoff and add-one unigram smoothing. Decoding lives exclusively in Zig.
"""
import argparse
from collections import Counter
import hashlib
import json
from multiprocessing import Pool
from pathlib import Path
import struct
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))
from homophone_bigram import Lex, HAN

BOS, EOS, UNK = '<s>', '</s>', '<unk>'
DISCOUNT = .75


def key(word):
    h = 0xcbf29ce484222325
    for b in word.encode():
        h = ((h ^ b) * 0x100000001b3) & ((1 << 64) - 1)
    return h


def initialize(path):
    global lex
    lex = Lex(Path(path))


def count_batch(texts):
    uni, pairs = Counter(), Counter()
    for text in texts:
        for match in HAN.finditer(text):
            words = [w if w in lex.score else UNK for w in lex.segment(match.group())]
            words.append(EOS)
            uni.update(words)
            pairs.update(zip([BOS] + words[:-1], words))
    return uni, pairs


def export(vocab, uni, pairs):
    vocab = set(vocab) | {BOS, EOS, UNK}
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
    args = p.parse_args()
    import pyarrow.parquet as pq
    root = Path(__file__).resolve().parent.parent
    sources = json.loads((root / 'third_party/HPLT/sources.json').read_text())
    lex_hash = hashlib.sha256(args.lexicon.read_bytes()).hexdigest()
    if lex_hash != sources['segmentation_lexicon']['sha256']:
        raise ValueError('segmentation lexicon differs from pinned HPLT build')
    unigram, pairs, provenance = Counter(), Counter(), []
    with Pool(args.jobs, initializer=initialize, initargs=(str(args.lexicon),)) as pool:
        for name, expected in sources['files'].items():
            path = args.shards / Path(name).name
            digest = hashlib.file_digest(path.open('rb'), 'sha256').hexdigest()
            if digest != expected:
                raise ValueError(f'shard hash mismatch: {path}')
            texts = []
            for batch in pq.ParquetFile(path).iter_batches(batch_size=1024, columns=['text']):
                texts.extend(batch.column(0).to_pylist()[:10000 - len(texts)])
                if len(texts) == 10000:
                    break
            for u, b in pool.imap(count_batch, [texts[i:i+100] for i in range(0, len(texts), 100)]):
                unigram.update(u)
                pairs.update(b)
            provenance.append({'file': name, 'sha256': digest, 'documents': len(texts)})
            print(f'{name}: {len(texts)} documents; {sum(unigram.values())} target tokens', flush=True)
    vocab = Lex(args.lexicon).score
    data = export(vocab, unigram, pairs)
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_bytes(data)
    manifest = {'version': 1, 'sources': provenance, 'lexicon_sha256': lex_hash,
                'discount': DISCOUNT, 'unigram_smoothing': 1, 'vocabulary': len(vocab)+3,
                'target_tokens': sum(unigram.values()), 'pairs': len(pairs),
                'model_sha256': hashlib.sha256(data).hexdigest(), 'bytes': len(data)}
    args.out.with_suffix('.json').write_text(json.dumps(manifest, indent=2)+'\n')
    print(json.dumps(manifest, indent=2))


if __name__ == '__main__':
    main()
