"""Fixed tradeoffs: full/sparse LMs, or --tiny-rerank PR83 capacity comparison.

Only previously seen dev sentences, same two seeds and real Zig Sessions.
Records quality/guards; /usr/bin/time peak RSS; and single-worker key latency.
This never consumes reserved external text or changes shipping defaults.
"""
import argparse
import gzip
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import subprocess
import time

import typing_eval as typing
from calibrate_decoder import ENV_KEYS, aggregate, changes
from eval_word_lm import guarded

PROFILES = {'default': None, 'full': Path('.cache/wordlm/pilot.bin'),
            '50k': Path('.cache/wordlm/sparse/pairs-50000.bin'),
            '200k': Path('.cache/wordlm/sparse/pairs-200000.bin')}


BASE_RESOURCES = None
TINY_RESOURCES = {}


def configure(model, name=None):
    if BASE_RESOURCES is not None:
        os.environ['MISSTYPE_RESOURCES']=str(TINY_RESOURCES.get(name, BASE_RESOURCES))
    for k in ENV_KEYS:os.environ.pop(k,None)
    if model:
        os.environ['MISSTYPE_WORD_LM']=str(model.resolve())
        os.environ['MISSTYPE_WORD_LM_WEIGHT']='0.5'
        # The search model replaces the reranker; don't allocate its unused table.
        os.environ['MISSTYPE_NO_HOMOPHONE']='1'


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--bin',type=Path,default=Path('.cache/wordlm/bin/sparse-dev'))
    p.add_argument('--out',type=Path,default=Path('.cache/wordlm/small-eval'))
    p.add_argument('--jobs',type=int,default=4)
    p.add_argument("--typing-memory-only",action="store_true",help="add actual 384-case typing RSS to an existing report")
    p.add_argument("--tiny-rerank", action="store_true", help="fixed PR83-family 50k/100k and no-context comparison")
    args=p.parse_args();args.out.mkdir(parents=True,exist_ok=True);typing.BIN=args.bin.resolve()
    global BASE_RESOURCES, PROFILES, TINY_RESOURCES
    BASE_RESOURCES=Path(os.environ['MISSTYPE_RESOURCES']).resolve()
    if args.tiny_rerank:
        PROFILES={name:None for name in ('default','none','pmi50k','pmi100k')}
        for name,count in [('none',None),('pmi50k',50000),('pmi100k',100000)]:
            target=(args.out/'resources'/name).resolve();target.mkdir(parents=True,exist_ok=True)
            for source in BASE_RESOURCES.iterdir():
                if source.is_file() and source.name!='homophone.bin':
                    link=target/source.name
                    if not link.exists():link.symlink_to(source)
            if count:
                link=target/'homophone.bin'
                if not link.exists():link.symlink_to(Path(f'.cache/wordlm/pmi-tiny/pairs-{count}.bin').resolve())
            TINY_RESOURCES[name]=target
    if args.typing_memory_only:
        report=json.loads((args.out/'report.json').read_text())
        if hashlib.file_digest(typing.BIN.open('rb'),'sha256').hexdigest()!=report['protocol']['binary_sha256']:
            raise ValueError('binary differs from quality report')
        cases=typing.build_cases(['dev','mixed-dev'],2,list(typing.ENGLISH_METHODS));chosen=[]
        for c in cases:
            if c.track=='zh' and c.expected not in chosen and len(chosen)<24:chosen.append(c.expected)
        batch=[c for c in cases if c.track=='zh' and c.expected in chosen]
        source=args.out/'typing-memory.tsv'
        source.write_text(''.join(f'{c.keys}\t{c.expected}\n' for c in batch))
        for name,model in PROFILES.items():
            configure(model,name)
            flag='-l' if platform.system()=='Darwin' else '-v'
            proc=subprocess.run(['/usr/bin/time',flag,str(typing.BIN),'--session-batch',str(source)],capture_output=True,text=True,check=True)
            pattern=r'(\d+)\s+maximum resident set size' if flag=='-l' else r'Maximum resident set size \(kbytes\):\s*(\d+)'
            peak=int(re.search(pattern,proc.stderr).group(1))*(1 if flag=='-l' else 1024)
            report['profiles'][name]['runtime']['typing_peak_rss_bytes']=peak
            report['profiles'][name]['runtime']['typing_peak_cases']=len(batch)
            print(name,'actual typing peak RSS bytes',peak,flush=True)
        (args.out/'report.json').write_text(json.dumps(report,ensure_ascii=False,indent=2)+'\n')
        return
    mode=subprocess.check_output([str(typing.BIN),'--build-mode'],text=True).strip()
    if mode not in ('fast','ReleaseFast'):raise ValueError('use ReleaseFast')
    binary_hash=hashlib.file_digest(typing.BIN.open('rb'),'sha256').hexdigest()
    protocol={'profiles':{name:json.loads(model.with_suffix('.json').read_text()) if model else None
                          for name,model in PROFILES.items()},'weight':.5,'set':'dev + mixed-dev',
              'seeds':2,'jobs':args.jobs,'binary_sha256':binary_hash,'commit':typing.git_commit(),
              'correction_protocol':typing.CORRECTION_PROTOCOL,'host':platform.platform(),
              'baseline':'shipping PR83 homophone table on; sparse/full replace it',
              'resources':{name:hashlib.sha256((Path(os.environ['MISSTYPE_RESOURCES'])/name).read_bytes()).hexdigest()
                           for name in ['lexicon.tsv','toneless.tsv','local_phrases.tsv','english.tsv','homophone.bin']}}
    protocol['family']='fixed PR83 PMI capacity' if args.tiny_rerank else 'full and sparse conditional word LM'
    if args.tiny_rerank:
        protocol['weight']=1.0
        pair_cache=Path.home()/'.cache/misstype/hplt/pairs_toneless.tsv'
        protocol['training']={'source_manifest_sha256':hashlib.sha256(Path('third_party/HPLT/sources.json').read_bytes()).hexdigest(),
            'pairs_sha256':hashlib.file_digest(pair_cache.open('rb'),'sha256').hexdigest(),
            'export_parameters':{'top_pairs':[50000,100000],'rank':'sqrt','ambiguity':'toneless','min_count':3,'cap':4,'smooth':3},
            'exposure':'existing pinned four-shard pair cache; conditional LM pilot uses first 10k docs per shard'}
        protocol['profiles']={}
        for name in PROFILES:
            table=TINY_RESOURCES.get(name,BASE_RESOURCES)/'homophone.bin'
            data=table.read_bytes() if table.exists() else b''
            protocol['profiles'][name]={'bytes':len(data),'gzip_bytes':len(gzip.compress(data,mtime=0)) if data else 0,
                'sha256':hashlib.sha256(data).hexdigest() if data else None}
    (args.out/'protocol.json').write_text(json.dumps(protocol,indent=2)+'\n')
    result={'protocol':protocol,'external_reserve_consumed':False,'profiles':{}}
    baseline=None
    for name,model in PROFILES.items():
        configure(model,name)
        if hashlib.file_digest(typing.BIN.open('rb'),'sha256').hexdigest()!=binary_hash:raise ValueError('binary changed')
        cases=typing.build_cases(['dev','mixed-dev'],2,list(typing.ENGLISH_METHODS))
        case_map={c.id:c for c in cases};ids=list(case_map)
        started=time.perf_counter();typing.run(cases,args.jobs)
        summary,rows=typing.score(cases)
        typing.save(args.out/f'{name}.json',protocol,summary,rows)
        if baseline is None:baseline=rows
        delta=changes(rows,baseline,ids)
        result['profiles'][name]={'eligible':guarded(rows,baseline,ids,case_map),
            'fewer':len(delta['fewer']),'more':len(delta['more']),
            'aggregate':aggregate(rows,ids,case_map),'summary':summary,
            'groups':{f'{track}:{persona}':aggregate(rows,[i for i in ids if case_map[i].track==track and case_map[i].persona==persona],case_map)
                      for track,persona in sorted({(c.track,c.persona) for c in cases})}}
        print(name,result['profiles'][name]['aggregate'],'guards',result['profiles'][name]['eligible'],
              'fewer/more',len(delta['fewer']),len(delta['more']),f'{time.perf_counter()-started:.1f}s',flush=True)
    # Serialize measurements after quality runs, without concurrent profiles.
    selected=[]
    for c in cases:
        if c.track=='zh' and c.expected not in selected and len(selected)<24:selected.append(c.expected)
    portable_cases=[{'id':c.id,'keys':c.keys} for c in cases if c.track=='zh' and c.expected in selected]
    (args.out/'wasm-cases.json').write_text(json.dumps(portable_cases,ensure_ascii=False)+'\n')
    for name,model in PROFILES.items():
        configure(model,name)
        peaks=[];startup=[]
        for _ in range(3):
            flag='-l' if platform.system()=='Darwin' else '-v'
            started=time.perf_counter()
            proc=subprocess.run(['/usr/bin/time',flag,str(typing.BIN),'--decode','su3cl3'],capture_output=True,text=True,check=True)
            startup.append((time.perf_counter()-started)*1000)
            pattern=r'(\d+)\s+maximum resident set size' if flag=='-l' else r'Maximum resident set size \(kbytes\):\s*(\d+)'
            peaks.append(int(re.search(pattern,proc.stderr).group(1))*(1 if flag=='-l' else 1024))
        batch=[c for c in typing.build_cases(['dev','mixed-dev'],2,list(typing.ENGLISH_METHODS))
               if c.track=='zh' and c.expected in selected]
        typing.run(batch,1);ms=[m for c in batch for m in c.result['ms']]
        result['profiles'][name]['runtime']={'peak_rss_bytes':peaks,'startup_plus_decode_ms':startup,
            'latency_cases':len(batch),'latency_keys':len(ms),'mean_ms':sum(ms)/len(ms),
            'p50_ms':typing.percentile(ms,.5),'p95_ms':typing.percentile(ms,.95),'max_ms':max(ms)}
        print(name,result['profiles'][name]['runtime'],flush=True)
    if hashlib.file_digest(typing.BIN.open('rb'),'sha256').hexdigest()!=binary_hash:raise ValueError('binary changed')
    (args.out/'report.json').write_text(json.dumps(result,ensure_ascii=False,indent=2)+'\n')


if __name__=='__main__':main()
