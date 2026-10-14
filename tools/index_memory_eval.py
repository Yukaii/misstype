"""Separate index construction ownership from native process peak RSS.

Run once before and once after a lifetime-only change, with isolated ReleaseFast
binaries. Quality uses the existing synthetic 7200-case Session protocol;
latency uses the fixed 384-case Chinese subset, plus its mixed-dev controls.
No external reserve or remote decoder is used.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import subprocess

import typing_eval as typing
from calibrate_decoder import ENV_KEYS


def digest(path):
    with path.open('rb') as f:
        return hashlib.file_digest(f, 'sha256').hexdigest()


def timed(command, **kwargs):
    darwin = platform.system() == 'Darwin'
    proc = subprocess.run(['/usr/bin/time', '-l' if darwin else '-v', *command],
                          capture_output=True, text=True, check=True, **kwargs)
    pattern = r'(\d+)\s+maximum resident set size' if darwin else r'Maximum resident set size \(kbytes\):\s*(\d+)'
    peak = int(re.search(pattern, proc.stderr).group(1)) * (1 if darwin else 1024)
    return proc.stdout, peak


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--probe', type=Path, required=True)
    p.add_argument('--dev', type=Path, required=True)
    p.add_argument('--out', type=Path, required=True)
    p.add_argument('--baseline', type=Path)
    args = p.parse_args()
    args.out.mkdir(parents=True, exist_ok=True)
    for key in ENV_KEYS:
        os.environ.pop(key, None)
    resources = Path(os.environ.get('MISSTYPE_RESOURCES', 'dist/MisstypeIME.app/Contents/Resources')).resolve()
    os.environ['MISSTYPE_RESOURCES'] = str(resources)
    typing.BIN = args.dev.resolve()
    if subprocess.check_output([str(typing.BIN), '--build-mode'], text=True).strip() not in ('ReleaseFast', 'fast'):
        raise ValueError('use ReleaseFast')
    result = {'host': platform.platform(), 'commit': typing.git_commit(),
              'dev_sha256': digest(typing.BIN), 'probe_sha256': digest(args.probe),
              'resources': {name: digest(resources/name) for name in
                            ['lexicon.tsv', 'toneless.tsv', 'local_phrases.tsv', 'english.tsv', 'homophone.bin']},
              'external_reserve_consumed': False, 'correction_protocol': typing.CORRECTION_PROTOCOL,
              'index_runs': {}}
    for mode in ('Chinese', 'Chinese-toneless', 'english'):
        runs = []
        for _ in range(3):
            stdout, peak = timed([str(args.probe.resolve()), str(resources), mode])
            runs.append({**json.loads(stdout), 'peak_rss_bytes': peak})
        result['index_runs'][mode] = runs
        print(mode, runs, flush=True)
    cases = typing.build_cases(['dev', 'mixed-dev', 'holdout', 'mixed-holdout'], 2, list(typing.ENGLISH_METHODS))
    typing.run(cases, 4)
    summary, rows = typing.score(cases)
    typing.save(args.out/'quality.json', result, summary, rows)
    result['quality_cases'] = len(cases)
    if args.baseline:
        # Compare saved files; in-memory rows differ from JSON in type only.
        old = json.loads((args.baseline/'quality.json').read_text())['cases']
        new = json.loads((args.out/'quality.json').read_text())['cases']
        if old.keys() != new.keys():
            raise ValueError('case set differs')
        changed = [i for i in new if new[i] != old[i]]
        result['changed_quality_cases'] = len(changed)
        result['changed_examples'] = changed[:10]
        print('quality changes', len(changed), flush=True)
    dev = typing.build_cases(['dev', 'mixed-dev'], 2, list(typing.ENGLISH_METHODS))
    selected = []
    for c in dev:
        if c.track == 'zh' and c.expected not in selected and len(selected) < 24:
            selected.append(c.expected)
    result['runtime'] = {}
    for name, batch in [('Chinese', [c for c in dev if c.track == 'zh' and c.expected in selected]),
                        ('mixed', [c for c in dev if c.track != 'zh'])]:
        typing.run(batch, 1)
        ms = [m for c in batch for m in c.result['ms']]
        # The mixed profile groups both feature settings for latency; RSS is
        # measured with automatic mixed-English enabled for all its traces.
        source = ''.join(f'{c.keys}\t{c.expected}\n' for c in batch)
        _, peak = timed([str(typing.BIN), '--session-batch', '-'] +
                        (['--mixed-english'] if name == 'mixed' else []), input=source)
        result['runtime'][name] = {'cases': len(batch), 'keys': len(ms),
            'mean_ms': sum(ms)/len(ms), 'p95_ms': typing.percentile(ms, .95),
            'max_ms': max(ms), 'typing_peak_rss_bytes': peak}
        print(name, result['runtime'][name], flush=True)
    portable = [{'id':c.id, 'keys':c.keys} for c in dev if c.track == 'zh' and c.expected in selected]
    (args.out/'wasm-cases.json').write_text(json.dumps(portable, ensure_ascii=False)+'\n')
    # The portable harness reads default.json's per-case previews.
    typing.save(args.out/'default.json', result, summary, rows)
    (args.out/'report.json').write_text(json.dumps(result, ensure_ascii=False, indent=2)+'\n')
    if args.baseline and result['changed_quality_cases']:
        raise SystemExit('lifetime-only experiment changed output')


if __name__ == '__main__':
    main()
