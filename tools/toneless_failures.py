"""Where do clean toneless sentences go wrong? (2026-10-14)

Reads a `typing_eval.py --save` run, takes one persona's distinct sentences
whose first preview (`shown`) is wrong, and replays each one's keys through
`misstype-dev --decode` to classify it:

  rank N    the whole-input decode lists the sentence at N (2..16): ranking
  rank 1    the decode is right, the session showed something else: session
  missing   not among the 16 candidates: pruned during the search

Optionally compares a second run (e.g. with MISSTYPE_WORD_LM) per sentence.
Offline; reads only synthetic eval sentences.

  python3 tools/typing_eval.py --bin BIN --set dev --save /tmp/dev.json
  python3 tools/toneless_failures.py /tmp/dev.json --bin BIN [--other /tmp/lm.json]
"""
import argparse
import json
import subprocess
from pathlib import Path


def distinct(cases, track, persona):
    out = {}
    for case_id, row in cases.items():
        t, p, _seed, expected = case_id.split('|', 3)
        if t == track and p == persona and expected not in out:
            out[expected] = row
    return out


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument('run', type=Path)
    p.add_argument('--bin', type=Path, required=True)
    p.add_argument('--track', default='zh')
    p.add_argument('--persona', default='clean-toneless')
    p.add_argument('--other', type=Path, help='second saved run to compare')
    args = p.parse_args()
    rows = distinct(json.loads(args.run.read_text())['cases'], args.track, args.persona)
    other = distinct(json.loads(args.other.read_text())['cases'], args.track, args.persona) if args.other else {}
    wrong = {e: r for e, r in rows.items() if r['shown'] != e}
    print(f'{len(wrong)} of {len(rows)} {args.track}/{args.persona} sentences start wrong')
    counts = {'ranking': 0, 'session': 0, 'pruned': 0}
    for expected, row in wrong.items():
        out = subprocess.run([str(args.bin), '--decode', row['keys']], capture_output=True, text=True, check=True).stdout
        texts = [line.split('\t')[0] for line in out.splitlines()[1:]]
        rank = texts.index(expected) + 1 if expected in texts else None
        kind = 'pruned' if rank is None else 'session' if rank == 1 else 'ranking'
        counts[kind] += 1
        note = ''
        if expected in other:
            note = '  other: ' + ('fixed' if other[expected]['shown'] == expected else 'still wrong')
        print(f'{kind:8} {"-" if rank is None else rank:>2}/{len(texts)}  {expected} | {row["shown"]}{note}')
    print(counts)
    if other:
        broken = [e for e, r in rows.items() if r['shown'] == e and other.get(e, r)['shown'] != e]
        print(f'other run breaks {len(broken)}:', ' '.join(broken))


if __name__ == '__main__':
    main()
