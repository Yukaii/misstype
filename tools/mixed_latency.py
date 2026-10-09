"""Per-keystroke cost of mixed Chinese/English recognition (Zig core).

Question: what does `mixedEnglish` add per key on toneless mixed input?
(Swift-era figure: ~110-130 ms; see docs/competitors-en.md.)

Types each dev sentence as one composition with an English word spliced in the
middle (Chinese pieces toneless or toned), through the real `Session`
(`misstype-dev --session-trace`), with mixed English off and on, and prints
mean/p95/max per-key latency. Offline; no user state. Needs a ReleaseFast build:

  (cd core-zig && ../script/zig/bootstrap.sh >/dev/null && zig build -Doptimize=ReleaseFast --prefix /tmp/mz)
  MISSTYPE_RESOURCES=dist/MisstypeIME.app/Contents/Resources \
    PYTHONPATH=src python tools/mixed_latency.py [/tmp/mz/bin/misstype-dev]
"""
import statistics
import subprocess
import sys

sys.path.insert(0, "tools")
from cursor_replay import encode, sentence_set

BIN = sys.argv[1] if len(sys.argv) > 1 else "/tmp/mz/bin/misstype-dev"
WORDS = ["meeting", "deadline", "project", "update", "schedule", "review"]
sents = sentence_set("dev")[:12]


def build(toned):
    out = []
    for i, (_, reading) in enumerate(sents):
        syl = reading.split()
        h = len(syl) // 2
        out.append((encode(" ".join(syl[:h]), toned), WORDS[i % len(WORDS)], encode(" ".join(syl[h:]), toned)))
    return out


def run(keys, mixed):
    cmd = [BIN, "--session-trace", keys] + (["--mixed-english"] if mixed else [])
    res = subprocess.run(cmd, capture_output=True, text=True)
    ms = [float(l.split("\t")[2]) for l in res.stdout.splitlines() if l.startswith("time\t")]
    final = next((l.split("\t", 1)[1] for l in res.stdout.splitlines() if l.startswith("final\t")), "")
    return ms, final


def stats(ms):
    s = sorted(ms)
    return f"n={len(s):4d} mean={statistics.mean(s):6.2f} p50={s[len(s)//2]:6.2f} p95={s[int(len(s)*.95)]:6.2f} max={s[-1]:6.2f} ms"


for toned in (False, True):
    pieces = build(toned)
    for label, make in (("chinese-only", lambda a, w, b: a + b), ("mixed input ", lambda a, w, b: a + w + b)):
        for mixed in (False, True):
            allms, hits = [], 0
            for a, w, b in pieces:
                ms, final = run(make(a, w, b), mixed)
                allms += ms
                hits += w in final if label.startswith("mixed") else 0
            extra = f" english_adopted={hits}/{len(pieces)}" if label.startswith("mixed") else ""
            print(f"toned={toned!s:5} {label} mixedEnglish={'on ' if mixed else 'off'} {stats(allms)}{extra}")
