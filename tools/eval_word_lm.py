"""Fixed-weight dev experiment through real Zig Sessions; no external test use.

Requires tools/word_lm.py pilot.bin and a ReleaseFast misstype-dev.
Runs baseline and three predeclared weights in matching case order/batches.
A model can advance only if it improves selection cost, preserves each
persona's recoverability and preserves typo-free accuracy (including mixed).
"""
import argparse
import hashlib
import json
import os
import subprocess
from pathlib import Path
import time

import typing_eval as typing
from calibrate_decoder import ENV_KEYS, aggregate, changes, eligible


def guarded(rows, baseline, ids, cases):
    # Keep Chinese and mixed controls independent: improvements in one cannot
    # compensate for a coverage/clean-accuracy loss in the other.
    return all(eligible(rows, baseline, [i for i in ids if cases[i].track == track], cases)
               for track in {cases[i].track for i in ids})


def latency(args, protocol):
    """Fixed small dev subset, one worker; warm-filesystem process startup."""
    all_cases = typing.build_cases(['dev', 'mixed-dev'], 2, list(typing.ENGLISH_METHODS))
    selected = []
    for c in all_cases:
        if c.track == 'zh' and c.expected not in selected and len(selected) < 24:
            selected.append(c.expected)
    results = {}
    for weight in (0, .5):
        os.environ.pop('MISSTYPE_WORD_LM', None)
        os.environ.pop('MISSTYPE_WORD_LM_WEIGHT', None)
        if weight:
            os.environ['MISSTYPE_WORD_LM'] = str(args.model.resolve())
            os.environ['MISSTYPE_WORD_LM_WEIGHT'] = str(weight)
        started = time.perf_counter()
        subprocess.run([str(typing.BIN), '--decode', 'su3'], capture_output=True, check=True)
        startup = time.perf_counter() - started
        cases = [c for c in typing.build_cases(['dev', 'mixed-dev'], 2, list(typing.ENGLISH_METHODS))
                 if c.track == 'zh' and c.expected in selected]
        typing.run(cases, 1)
        summary, _ = typing.score(cases)
        ms = [m for c in cases for m in c.result['ms']]
        results[str(weight)] = {
            'startup_plus_one_decode_ms': round(startup * 1000, 1),
            'cases': len(cases), 'keys': len(ms), 'mean_ms': round(sum(ms) / len(ms), 3),
            'p50_ms': typing.percentile(ms, .5), 'p95_ms': typing.percentile(ms, .95),
            'max_ms': max(ms), 'summary': summary,
        }
        print(weight, {k: v for k, v in results[str(weight)].items() if k != 'summary'}, flush=True)
        if hashlib.file_digest(typing.BIN.open('rb'), 'sha256').hexdigest() != protocol['binary_sha256']:
            raise ValueError('decoder executable changed during latency evaluation')
    (args.out / 'latency.json').write_text(json.dumps(results, indent=2) + '\n')


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--bin', type=Path, default=typing.APP_BIN, help='use an isolated ReleaseFast executable')
    p.add_argument('--model', type=Path, default=Path('.cache/wordlm/pilot.bin'))
    p.add_argument('--out', type=Path, default=Path('.cache/wordlm/dev'))
    p.add_argument('--jobs', type=int, default=8)
    p.add_argument('--latency', action='store_true', help='measure fixed 384-case dev subset with one worker')
    p.add_argument('--summarize', action='store_true', help='recompute guards from saved profiles without decoding')
    args = p.parse_args()
    typing.BIN = args.bin.resolve()
    for k in ENV_KEYS:
        os.environ.pop(k, None)
    args.out.mkdir(parents=True, exist_ok=True)
    model_hash = hashlib.file_digest(args.model.open('rb'), 'sha256').hexdigest()
    protocol = {'model_sha256': model_hash, 'weights': [0, .1, .25, .5],
                'set': 'dev + mixed-dev', 'seeds': 2, 'jobs': args.jobs,
                'binary_sha256': hashlib.file_digest(typing.BIN.open('rb'), 'sha256').hexdigest(),
                'commit': typing.git_commit(),
                'resources': {name: hashlib.sha256((Path(os.environ['MISSTYPE_RESOURCES']) / name).read_bytes()).hexdigest()
                              for name in ('lexicon.tsv', 'toneless.tsv', 'local_phrases.tsv', 'english.tsv', 'homophone.bin')},
                'model': json.loads(args.model.with_suffix('.json').read_text())}
    (args.out / 'protocol.json').write_text(json.dumps(protocol, indent=2)+'\n')
    mode = subprocess.run([str(typing.BIN), '--build-mode'], capture_output=True, text=True, check=True).stdout.strip()
    if mode not in ('fast', 'ReleaseFast'):
        raise ValueError('build ReleaseFast before comparing latency')
    if args.latency:
        latency(args, protocol)
        return
    results, summaries = {}, {}
    for weight in protocol['weights']:
        if weight:
            os.environ['MISSTYPE_WORD_LM'] = str(args.model.resolve())
            os.environ['MISSTYPE_WORD_LM_WEIGHT'] = str(weight)
        else:
            os.environ.pop('MISSTYPE_WORD_LM', None)
            os.environ.pop('MISSTYPE_WORD_LM_WEIGHT', None)
        cases = typing.build_cases(['dev', 'mixed-dev'], 2, list(typing.ENGLISH_METHODS))
        case_map = {c.id: c for c in cases}
        if args.summarize:
            saved = json.loads((args.out / f'w{weight}.json').read_text())
            if any(saved['meta'].get(k) != protocol[k] for k in ('model_sha256', 'jobs', 'seeds', 'set')):
                raise ValueError('saved results belong to a different model')
            results[weight], summaries[weight] = saved['cases'], saved['summary']
            if set(results[weight]) != set(case_map):
                raise ValueError('saved case set differs')
            continue
        if hashlib.file_digest(typing.BIN.open('rb'), 'sha256').hexdigest() != protocol['binary_sha256']:
            raise ValueError('decoder executable changed during evaluation; use an isolated copy')
        started = time.perf_counter()
        typing.run(cases, args.jobs)
        if hashlib.file_digest(typing.BIN.open('rb'), 'sha256').hexdigest() != protocol['binary_sha256']:
            raise ValueError('decoder executable changed during evaluation; discard this run')
        summary, rows = typing.score(cases)
        typing.save(args.out / f'w{weight}.json', {**protocol, 'weight': weight, 'build': 'ReleaseFast'}, summary, rows)
        results[weight], summaries[weight] = rows, summary
        print(f'weight {weight}: {len(cases)} cases, {time.perf_counter()-started:.1f}s', flush=True)
    ids = list(case_map)
    baseline = results[0]
    report = {'protocol': protocol, 'profiles': {}}
    for weight, rows in results.items():
        delta = changes(rows, baseline, ids)
        report['profiles'][str(weight)] = {
            'eligible': guarded(rows, baseline, ids, case_map),
            'fewer': len(delta['fewer']), 'more': len(delta['more']),
            'aggregate': aggregate(rows, ids, case_map),
            'personas': {persona: aggregate(rows, [i for i in ids if case_map[i].persona == persona], case_map)
                        for persona in sorted({c.persona for c in cases})},
            'summary': summaries[weight],
            'examples': [{'expected': case_map[i].expected, 'keys': case_map[i].keys,
                          'before': baseline[i], 'after': rows[i]} for i in delta['more'][:8]],
        }
    candidates = [w for w in results if w and report['profiles'][str(w)]['eligible']
                  and aggregate(results[w], ids, case_map)['picks'] < aggregate(baseline, ids, case_map)['picks']]
    report['advance'] = min(candidates, key=lambda w: (aggregate(results[w], ids, case_map)['picks'], w)) if candidates else None
    (args.out / 'report.json').write_text(json.dumps(report, ensure_ascii=False, indent=2)+'\n')
    print(json.dumps({w: {k: v for k, v in r.items() if k in ('eligible', 'fewer', 'more', 'aggregate')} for w, r in report['profiles'].items()}, indent=2))
    print(f"advance: {report['advance']}")


if __name__ == '__main__':
    main()
