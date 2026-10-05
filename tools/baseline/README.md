# Cross-IME baseline: Misstype vs vChewing

Question: on the same noisy keystrokes, how many characters does the user have
to fix, and how does it *feel*? This directory holds the quantitative harness
and the manual protocol. It measures end-to-end results (engine + lexicon), so
it is **not** a decoder-only comparison; see "Confounds".

## Quantitative (headless, Linux, Docker)

```sh
PYTHONPATH=src python tools/baseline/make_probes.py > tools/baseline/probes.tsv   # once
PYTHONPATH=src python tools/baseline/compare.py gen --seeds 10 --out /tmp/inputs.tsv

# Misstype: build the C ABI, then drive it (glibc: run the driver in the same
# kind of container the .so was built in, host glibc may be older)
script/linux/build_capi.sh          # inside the Linux container; see docs/linux-port.md
python tools/baseline/compare.py drive-misstype --lib libMisstypeCAPI.so \
    --resources <dir with lexicon.tsv, toneless.tsv, local_phrases.tsv> \
    --inputs /tmp/inputs.tsv --out /tmp/mt.tsv

# vChewing: LibVanguard at pinned commits, real factory lexicon, headless
tools/baseline/run_vchewing.sh /tmp/inputs.tsv /tmp/vc.tsv default,furious

python tools/baseline/compare.py report /tmp/mt.tsv /tmp/vc.tsv
```

Noise configs and seeds are `tools/keynoise.py`'s (stable md5 seeds). Per
(engine, config): `perfect` (share of inputs committed exactly right),
`errors` (mean character edit distance to the target = characters to fix),
`cer`, `ms` (median in-process typing + Enter).

vChewing configs: `default` (a fresh install), `furious` (注音狂打 on, off by
default), `mixed` (中英混打, off by default; irrelevant for Chinese-only probes).

Probes: `probes.tsv` (42 everyday sentences, 2–12 syllables, no neutral tones,
no 一/不 sandhi). `report` drops probes that some engine already misses on
CLEAN keystrokes (homophone/variant disagreements such as 交/教, 宣布/宣佈)
because they say nothing about noise; use `--all` to keep them.

### Pitfall that produced a bogus first result

vChewing loads its factory lexicon **asynchronously** by default. A harness
that types without yielding to the main queue sees `factoryTrie == nil` and the
engine falls back to bare single characters at a flat -9.5 score
("我市學生", "天企", 0 multi-syllable words). The harness sets
`LXFacade.asyncLoadingUserData = false` before connecting. When touching the
harness, sanity-check clean output first (`compare.py report` prints the
excluded probes) and query `unigramsFor(["ㄊㄧㄢ","ㄑㄧˋ"])`: it must return 天氣.

### What is and is not measurable (2026-10-05)

The harness types the keys and presses Enter, then reads what was committed.
That matches how vChewing is used when every syllable is complete (tones typed).
It does **not** match vChewing's toneless path: with an unfinished syllable
pending, Enter commits nothing (420/420 `no-tones`, 418/420 `harsh`), and 注音狂打
is driven through a copilot candidate window picked with Shift+key, which this
harness does not emulate. The displayed preedit is not a fair substitute either
("今天天七哏"). So **vChewing's `no-tones` and `harsh` rows are not results**;
only the manual protocol can compare toneless typing. In the tone-bearing
configs about 7% (`drop-key`) and 5% (`swap`) of vChewing inputs also commit
nothing because a syllable was left incomplete; the table counts them as fully
wrong, and the "excluding empty" variant is given below.

Run 2026-10-05, 35 probes x 10 seeds, synthetic noise, Misstype at 0c6d1c6+
vs LibVanguard `8a3f8d8` with the Vanguard lexicon `d41f2fc` (perfect / mean
chars to fix):

| config | Misstype | vChewing default | vChewing furious | default, excl. empty |
| --- | --- | --- | --- | --- |
| clean | 1.00 / 0.00 | 1.00 / 0.00 | 1.00 / 0.00 | |
| drop-key-5 | 0.52 / 0.79 | 0.31 / 1.83 | 0.34 / 1.71 | 0.34 / 1.40 |
| swap-5 | 0.44 / 1.52 | 0.53 / 1.38 | 0.53 / 1.65 | 0.56 / 1.02 |
| sub-5+wrongtone-10 | 0.47 / 1.06 | 0.22 / 1.75 | 0.22 / 1.83 | 0.22 / 1.75 |

Read it as a rough ranking on synthetic noise, one run, lexicons differ:
Misstype is ahead on dropped keys and neighbor substitutions and slightly
behind on adjacent swaps. Timings are not comparable across engines (Misstype
is driven through the C ABI, vChewing through a debug build of its test target).

### Confounds (read before quoting numbers)

- Different lexicons: Misstype uses the McBopomofo lexicon, vChewing its
  Vanguard lexicon (MOE-derived). Variant choices (週/周, 佈/布) show up as
  "errors". Probes were chosen to avoid the common ones, not all.
- Different defaults: vChewing's tone-optional and mixed modes are off in a
  fresh install, so `default` shows what a new user gets, `furious` the best
  toneless case.
- Synthetic noise, not human errors. Key-order slips and neighbor hits are
  uniform here; real typing is not. Treat results as a regression signal and
  a rough ranking, not a user study.
- Single-run timings in a container; `ms` is only comparable within a run.

vChewing's code is LGPL-3.0-or-later. It is fetched into `.cache/baseline/`
(gitignored) at pinned commits and only the harness test file we wrote
(`vchewing/BaselineHarness.swift`, MIT) is copied into that checkout. Nothing
of vChewing is vendored or linked into Misstype.

## Subjective (manual, macOS)

See `feel_protocol.md`.
