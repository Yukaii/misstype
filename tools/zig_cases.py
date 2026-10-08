"""Generate synthetic decoder, Unicode and touch fixtures for Swift/Zig parity."""
import json
import math
from pathlib import Path
import random
import sys
ROOT = Path(__file__).resolve().parents[1]
LEFT = '1qaz2ws34erdfcvxg5bt'
RIGHT = '8ik,9ol67yuhjnm0/p.;-'
XY = [(0.15,.2),(.3,.2),(.3,.5),(.3,.8),(.5,.2),(.5,.5),(.5,.8),(.7,.1),(.88,.1),(.7,.23),(.88,.23),(.7,.36),(.88,.36),(.7,.49),(.88,.49),(.7,.62),(.88,.62),(.7,.75),(.88,.75),(.7,.88),(.88,.88)]
POS = {key:(surface,*xy) for surface,keys in [('left',LEFT),('right',RIGHT)] for key,xy in zip(keys,XY)}

def cases():
    rng = random.Random(487)
    probes = [line.split('\t')[:2] for line in (ROOT/'tools/baseline/probes.tsv').read_text().splitlines() if line and not line.startswith('#')]
    for name, keys in probes:
        stripped = ''.join(k for k in keys if k not in '3467 ')
        variants = [('exact',keys),('toneless',stripped),('dropped',keys[:len(keys)//2]+keys[len(keys)//2+1:]),('swapped',keys[1]+keys[0]+keys[2:]),('inserted',keys[:2]+'m'+keys[2:]),('neighbor',keys.replace('u','m',1)),('tone',keys.replace('3','4',1))]
        for kind,value in variants:
            for strength in [0,2,3]:
                yield dict(id=f'{name}-{kind}-{strength}',mode='keys',keys=value,fuzzy=strength!=0,strength=strength)
        # Same public layout and seeded disk jitter as the measurements; no traces.
        for radius in [0,.08,.12]:
            for seed in range(2):
                taps=[]
                for key in keys:
                    if key==' ': continue  # Space has no touch centre.
                    surface,x,y=POS[key]
                    angle=rng.random()*2*math.pi; r=radius*math.sqrt(rng.random())
                    taps.append(dict(surface=surface,x=max(0,min(1,x+r*math.cos(angle))),y=max(0,min(1,y+r*math.sin(angle)))))
                for algorithm in ['beam','lattice']:
                    yield dict(id=f'{name}-touch-{radius}-{seed}-{algorithm}',mode='touch',taps=taps,algorithm=algorithm)
                yield dict(id=f'{name}-touch-{radius}-{seed}-nearest',mode='touch',taps=taps,spatial=False)
    for index,text in enumerate(['你好','𠀀你','e\u0301','🇹🇼','👨‍👩‍👧‍👦','👍🏽','a\u200db','\r\n','각','क्ष','क\u093e','\u0600A','A\u2028B']):
        yield dict(id=f'unicode-{index}',mode='unicode',text=text)
    for index,text in enumerate(['你好','𠀀你','e\u0301','🇹🇼','👨‍👩‍👧‍👦','👍🏽','각','क्ष','क\u093e','\u0600A','bad word']):
        yield dict(id=f'dictionary-{index}',mode='dictionary',text=text)

if __name__=='__main__':
    Path(sys.argv[1]).write_text(''.join(json.dumps(row,ensure_ascii=False)+'\n' for row in cases()))
