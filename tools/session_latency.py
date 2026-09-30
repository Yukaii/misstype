"""Per-key latency and final text with and without chunked auto-commit.

Question (user report 2026-09-29): the IME gets laggy as one composition
grows, because every key re-decodes the whole thing. Does committing the
settled head in chunks bound the latency without changing the result?

Types 12 synthetic dev sentences as one continuous composition (toned and
toneless) through the real `InputSession` (`--session-trace`), at
autocommit 0 (off), 24 and 16 syllables, and prints mean/p95/max per-key
latency plus similarity of the final text to the expected one. Offline and
deterministic apart from timing; no user lexicon.

Usage:
  ./script/build_and_run.sh --build-only
  PYTHONPATH=src python tools/session_latency.py
"""

import subprocess,sys,statistics
sys.path.insert(0,'tools')
from cursor_replay import APP_BIN, encode, sentence_set
sents=sentence_set('dev')[:12]
truth="".join(t for t,_ in sents)
def run(keys, ac):
    out=subprocess.run([str(APP_BIN),"--session-trace",keys,"--auto-commit",str(ac)],capture_output=True,text=True).stdout
    ms=[float(l.split("\t")[2]) for l in out.splitlines() if l.startswith("time\t")]
    chunks=[l for l in out.splitlines() if l.startswith("chunk\t")]
    final=[l for l in out.splitlines() if l.startswith("final\t")][0].split("\t",1)[1]
    return ms,chunks,final
def cer(a,b):
    import difflib
    return 1-difflib.SequenceMatcher(None,a,b).ratio()
for toned in (True,False):
    keys=encode(" ".join(r for _,r in sents),toned)
    for ac in (0,24,16):
        ms,chunks,final=run(keys,ac)
        print(f"toned={toned} autocommit={ac:2d} keys={len(ms)} chunks={len(chunks)} mean={statistics.mean(ms):6.1f}ms p95={sorted(ms)[int(len(ms)*.95)]:6.1f}ms max={max(ms):6.1f}ms  sim_to_truth={1-cer(final,truth):.3f} len={len(final)}/{len(truth)}")
