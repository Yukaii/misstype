"""Export a fixed-budget sparse model from full MWLM counts (no new corpus).

MSLM v1: same 32-byte header; word records <Qff> hash, unigram probability,
backoff mass; sorted pair records <IIf> history ID, target ID, direct mass.
All unigram vocabulary is retained. Removed discounted pair mass backs off.
This count-ranked pilot is not Stolcke's entropy-pruning algorithm.
"""
import argparse
import gzip
import hashlib
import heapq
import json
import mmap
from pathlib import Path
import struct


def export(words, pairs, tokens, discount=.75):
    from word_lm import key, BOS, EOS, UNK
    if not 0 < discount < 1 or sum(row[1] for row in words) != tokens:
        raise ValueError('invalid full-model counts')
    if any(words[i-1][0] >= words[i][0] for i in range(1,len(words))):
        raise ValueError('vocabulary hashes not unique and sorted')
    ids = {h: i for i, (h, _, _, _) in enumerate(words)}
    if not {key(BOS),key(EOS),key(UNK)} <= ids.keys():raise ValueError('missing special symbols')
    if len({(h,w) for h,w,_ in pairs}) != len(pairs):raise ValueError('duplicate retained pair')
    mass = [0.0] * len(words)
    records = []
    for h, w, count in sorted(pairs):
        hi, wi = ids[h], ids[w]
        if count <= discount or words[hi][2] == 0 or w == key(BOS):raise ValueError('invalid retained pair')
        direct = (count-discount) / words[hi][2]
        mass[hi] += direct
        records.append((hi, wi, direct))
    data = bytearray(struct.pack('<4sIIIQd', b'MSLM', 1, len(words), len(records), tokens, discount))
    if any(m >= 1 for m in mass):raise ValueError('retained mass leaves no backoff')
    # BOS is a context only, not a target in the smoothed vocabulary.
    from word_lm import key, BOS
    bos = key(BOS)
    for i, (h, count, _, _) in enumerate(words):
        unigram = 0 if h == bos else (count+1) / (tokens+len(words)-1)
        data.extend(struct.pack('<Qff', h, unigram, 1-mass[i]))
    for row in records:
        data.extend(struct.pack('<IIf', *row))
    return bytes(data)


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--source', type=Path, default=Path('.cache/wordlm/pilot.bin'))
    p.add_argument('--out', type=Path, default=Path('.cache/wordlm/sparse'))
    args=p.parse_args()
    manifest=json.loads(args.source.with_suffix('.json').read_text())
    actual=hashlib.file_digest(args.source.open('rb'),'sha256').hexdigest()
    if actual!=manifest['model_sha256']:raise ValueError('source model hash mismatch')
    with args.source.open('rb') as f, mmap.mmap(f.fileno(),0,access=mmap.ACCESS_READ) as data:
        magic,version,n,m,tokens,discount=struct.unpack_from('<4sIIIQd',data)
        if (magic,version)!=(b'MWLM',1) or len(data)!=32+(n+m)*20:raise ValueError('invalid full model')
        words=[struct.unpack_from('<QIII',data,32+i*20) for i in range(n)]
        heap=[]
        for h,w,c in struct.iter_unpack('<QQI',memoryview(data)[32+n*20:]):
            item=(c,-h,-w)
            if len(heap)<200000:heapq.heappush(heap,item)
            elif item>heap[0]:heapq.heapreplace(heap,item)
        ranked=sorted(heap,reverse=True)
        args.out.mkdir(parents=True,exist_ok=True)
        for budget in (50000,200000):
            kept=[(-h,-w,c) for c,h,w in ranked[:budget]]
            binary=export(words,kept,tokens,discount)
            path=args.out/f'pairs-{budget}.bin'
            path.write_bytes(binary)
            compressed=gzip.compress(binary,compresslevel=9,mtime=0)
            path.with_suffix('.bin.gz').write_bytes(compressed)
            meta={**manifest,'format':'MSLM-v1','source_model_sha256':actual,
                  'pairs':len(kept),'source_pairs':manifest['pairs'],
                  'pruning':'highest count, hash order breaks ties','retained_pairs':len(kept),
                  'pair_budget':budget,'probability_precision':'float32',
                  'model_sha256':hashlib.sha256(binary).hexdigest(),'bytes':len(binary),
                  'gzip_bytes':len(compressed)}
            path.with_suffix('.json').write_text(json.dumps(meta,indent=2)+'\n')
            print(json.dumps(meta),flush=True)


if __name__=='__main__':main()
