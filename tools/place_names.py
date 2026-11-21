"""Taiwan place names from government open data, as dictionary rows.

Question: about half of first-choice misses sit where the dictionary lacks
a word, and many are place names (翠屏里, 裕農路, 泰源, stations). The
Ministry of the Interior publishes them under the Open Government Data
License v1 (attribution; compatible with CC BY 4.0):

  roads     全國路名資料 (data.gov.tw dataset 35321), one CSV per year
  villages  代碼服務－村里清單 (dataset 102017): NLSC API, counties ->
            districts -> villages

`fetch` downloads into ~/.cache/misstype/gov (nothing user-typed is ever
sent); `build` turns names into lexicon rows:

  - the full name (裕農路, 翠屏里, 三星鄉) and, for a road or a village, its
    stem when the stem is two or more characters (裕農, 翠屏): people type
    裕農路 but also say 翠屏 alone
  - readings from each character's dictionary entries; a character with
    several readings takes its best-scored one and the row is flagged
    `polyphone` so the choice can be reviewed (unknown characters drop the
    name)
  - one score per kind, a rare-word level calibrated against existing
    place words (--score): a name must not outrank common words

Usage:
  python3 tools/place_names.py fetch [--year 115]
  python3 tools/place_names.py build --lexicon dist/.../lexicon.tsv --out .cache/gov/places.tsv

script/build_and_run.sh appends .cache/gov/places.tsv to the bundled
local_phrases.tsv when it exists. Pair it with a word model built on the same
file (`tools/word_lm.py --extra-lexicon .cache/gov/places.tsv`): added
without retraining, unknown names fall back to UNK and obscure stems beat
everyday words (lab notebook, 2026-11-21).
"""
import argparse
import csv
import io
import re
import sys
import time
import urllib.request
import xml.etree.ElementTree as ET
from collections import defaultdict
from pathlib import Path

CACHE = Path.home() / '.cache/misstype/gov'
ROADS = ('https://opdadm.moi.gov.tw/api/v1/no-auth/resource/api/dataset/'
         'E2EDC47D-2D3F-4EB1-878A-4DEB6160FD4C/resource/EB1B8C49-5C2A-42E0-8CC3-6B69B37DA66F/download')
NLSC = 'https://api.nlsc.gov.tw/other'
AGENT = {'User-Agent': 'Mozilla/5.0 (open-data fetch)'}
HAN = re.compile(r'^[一-鿿]+$')


def get(url: str) -> bytes:
    with urllib.request.urlopen(urllib.request.Request(url, headers=AGENT), timeout=60) as r:
        return r.read()


def fetch(args) -> int:
    (CACHE / 'roads').mkdir(parents=True, exist_ok=True)
    (CACHE / 'roads' / f'{args.year}.csv').write_bytes(get(ROADS))
    rows = []
    counties = ET.fromstring(get(f'{NLSC}/ListCounty'))
    for county in counties.iter('countyItem'):
        code, cname = county.findtext('countycode'), county.findtext('countyname')
        towns = ET.fromstring(get(f'{NLSC}/ListTown/{code}'))
        for town in towns.iter('townItem'):
            tcode, tname = town.findtext('towncode'), town.findtext('townname')
            time.sleep(0.2)
            for v in ET.fromstring(get(f'{NLSC}/ListVillage/{code}/{tcode}')).iter('village'):
                rows.append((cname, tname, v.findtext('villageName')))
        print(f'{cname}: {len(rows)} villages so far', flush=True)
    with (CACHE / 'villages.tsv').open('w', encoding='utf-8') as fh:
        fh.write('county\ttown\tvillage\n')
        fh.writelines(f'{c}\t{t}\t{v}\n' for c, t, v in rows)
    print(f'{len(rows)} villages -> {CACHE / "villages.tsv"}')
    return 0


def char_readings(paths):
    best = {}
    many = defaultdict(set)
    for path in paths:
        for line in Path(path).read_text(encoding='utf-8').splitlines():
            if not line or line.startswith('#'):
                continue
            f = line.split('\t')
            if len(f) < 3 or len(f[1]) != 1:
                continue
            try:
                score = float(f[2])
            except ValueError:
                continue
            many[f[1]].add(f[0])
            if f[1] not in best or score > best[f[1]][1]:
                best[f[1]] = (f[0], score)
    return {c: r for c, (r, _) in best.items()}, many


def words(paths):
    out = set()
    for path in paths:
        for line in Path(path).read_text(encoding='utf-8').splitlines():
            f = line.split('\t')
            if len(f) >= 2:
                out.add(f[1])
    return out


def names():
    """(kind, name) from the cached sources, deduplicated."""
    found = set()
    roads = sorted((CACHE / 'roads').glob('*.csv'))
    if roads:
        for row in csv.DictReader(io.StringIO(roads[-1].read_text(encoding='utf-8-sig'))):
            road = row['road'].strip()
            found.add(('road', road))
            town = row['site_id'][len(row['city']):]
            found.add(('district', town))
            found.add(('city', row['city']))
    villages = CACHE / 'villages.tsv'
    if villages.exists():
        for line in villages.read_text(encoding='utf-8').splitlines()[1:]:
            county, town, village = line.split('\t')
            found.update({('city', county), ('district', town), ('village', village)})
    return found


def stem(kind: str, name: str) -> str | None:
    if kind == 'road':
        m = re.match(r'^(.+?)(?:[東西南北中]?[一二三四五六七八九十]*(?:路|街|大道))$', name)
    elif kind == 'village':
        m = re.match(r'^(.+?)[村里]$', name)
    else:
        m = None
    return m.group(1) if m and len(m.group(1)) >= 2 else None


def build(args) -> int:
    reading, many = char_readings(args.lexicon)
    known = words(args.lexicon)
    rows = {}
    for kind, name in sorted(names()):
        for text in filter(None, (name, stem(kind, name))):
            if text in known or text in rows or not HAN.match(text) or len(text) < 2:
                continue
            if any(c not in reading for c in text):
                continue
            polyphone = any(len(many[c]) > 1 for c in text)
            rows[text] = ('-'.join(reading[c] for c in text), args.score, kind, polyphone)
    with args.out.open('w', encoding='utf-8') as fh:
        fh.write('# Taiwan place names, Ministry of the Interior open data (Open Government Data License v1); '
                 'tools/place_names.py. Columns: reading text score kind polyphone\n')
        for text, (r, score, kind, poly) in sorted(rows.items()):
            fh.write(f'{r}\t{text}\t{score}\t{kind}\t{poly}\n')
    by = defaultdict(int)
    for _, _, kind, _ in rows.values():
        by[kind] += 1
    print(f'{len(rows)} rows -> {args.out}: {dict(by)}; polyphone {sum(r[3] for r in rows.values())}')
    return 0


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest='cmd', required=True)
    f = sub.add_parser('fetch')
    f.add_argument('--year', default='115')
    b = sub.add_parser('build')
    b.add_argument('--lexicon', type=Path, action='append', required=True)
    b.add_argument('--score', type=float, default=-14.0)
    b.add_argument('--out', type=Path, required=True)
    args = p.parse_args()
    return fetch(args) if args.cmd == 'fetch' else build(args)


if __name__ == '__main__':
    sys.exit(main())
