"""Report offline synthetic top-1/top-5 quality for the broad parity corpus."""
import collections
import json
from pathlib import Path
import sys
expected = {row.split('\t')[0]: row.split('\t')[2] for row in Path('tools/baseline/probes.tsv').read_text().splitlines() if row and not row.startswith('#')}
results = collections.defaultdict(list)
for line in Path(sys.argv[2]).read_text().splitlines():
    row = line.split('\t')
    if row[0] == 'C':
        results[row[1]].append(row[3])
groups = collections.defaultdict(lambda: [0, 0, 0])
for raw in Path(sys.argv[1]).read_text().split('\n'):
    if not raw:
        continue
    case = json.loads(raw)
    if case['mode'] not in ('keys', 'touch'):
        continue
    name = next(name for name in sorted(expected, key=len, reverse=True) if case['id'].startswith(name + '-'))
    group = case['id'][len(name) + 1:]
    if case['mode'] == 'touch':
        parts = group.split('-')
        group = 'touch-' + parts[1] + '-' + parts[-1]
    else:
        group = group.rsplit('-', 1)[0]
    values = results[case['id']]
    score = groups[group]
    score[0] += 1
    score[1] += bool(values and values[0] == expected[name])
    score[2] += expected[name] in values[:5]
for group, (count, top1, top5) in sorted(groups.items()):
    print(f'quality: {group} n={count} top1={top1/count:.1%} top5={top5/count:.1%}')
