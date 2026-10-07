# Cross-IME baseline: Misstype vs vChewing and libchewing

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

## libchewing (headless, native macOS or Linux)

```sh
PYTHONPATH=src python tools/baseline/compare.py gen --seeds 10 --out /tmp/inputs.tsv
tools/baseline/run_libchewing.sh /tmp/inputs.tsv /tmp/lc.tsv chewing,fuzzy

# Misstype on macOS: the C ABI builds as a dylib, resources from the app build
swift build -c release --product MisstypeCAPI
./script/build_and_run.sh --build-only
python tools/baseline/compare.py drive-misstype --lib .build/release/libMisstypeCAPI.dylib \
    --resources dist/MisstypeIME.app/Contents/Resources --inputs /tmp/inputs.tsv --out /tmp/mt.tsv

python tools/baseline/compare.py report --losses misstype /tmp/mt.tsv /tmp/lc.tsv
```

`run_libchewing.sh` builds libchewing v0.13.1 from Codeberg (upstream; the
GitHub mirror stops at 0.12) with its libchewing-data submodule into
`.cache/baseline/`. Needs cmake, ninja and Rust. libchewing is
LGPL-2.1-or-later and is only driven through ctypes from that cache; nothing
is vendored or linked into Misstype.

Driver settings: Dachen layout, Space is the first tone (not selection),
auto-learn off and a throwaway user dictionary, so no probe biases the next,
auto-commit threshold at the 39-syllable maximum, Enter commits. Engines:
`chewing` (the default `ChewingEngine`: DAG shortest path over phrase
log-probabilities plus a length prior) and `fuzzy` (`FuzzyChewingEngine`: the
same, with partial-syllable prefix lookup). libchewing's Zhuyin editor is
slot-based: the initial, medial and final go to fixed slots whatever order
they are typed in.

`--losses ENGINE` lists every input ENGINE gets wrong while another engine is
exact; those are the cases to turn into fixtures.

Run 2026-10-07, 42 probes x 10 seeds, Misstype at 47a1a2c+ (macOS, release
dylib) vs libchewing v0.13.1 (`f071d2e`, data `bfba418`). 11 probes are
excluded as not clean-correct on every engine (31 kept). Perfect / mean
characters to fix:

| config | Misstype | chewing | fuzzy |
| --- | --- | --- | --- |
| clean | 1.00 / 0.00 | 1.00 / 0.00 | 1.00 / 0.00 |
| no-tones | 0.94 / 0.10 | 0.00 / 7.48 | 0.00 / 7.48 |
| drop-key-5 | 0.54 / 0.81 | 0.33 / 1.87 | 0.47 / 1.44 |
| swap-5 | 0.43 / 1.55 | 0.52 / 1.37 | 0.34 / 2.10 |
| sub-5+wrongtone-10 | 0.46 / 1.08 | 0.20 / 1.88 | 0.23 / 1.78 |
| harsh | 0.16 / 4.26 | 0.00 / 7.48 | 0.00 / 7.47 |

As with vChewing, libchewing's `no-tones` and `harsh` rows are not results: a
syllable not closed by a tone is never committed on Enter. Median time per
input (typing + Enter): Misstype 7–12 ms toned, ~50 ms toneless; libchewing
under 1.5 ms.

What it says about Misstype (the tuning targets):

1. **Initial/medial order slips inside a syllable** — 32 of the 42 losses
   (swap-5). ㄅㄧㄢ typed as ㄧㄅㄢ decodes as 一 + 半 (方一半), ㄊㄧㄢ as
   ㄧㄊㄢ gives 一嘆, ㄍㄨㄥ as ㄨㄍㄥ gives 無耕: splitting off a toneless
   ㄧ/ㄨ/ㄛ syllable is cheaper than the transposition repair. libchewing's
   slot editor makes these slips free.
   **Addressed** (branch `decoder/syllable-order-slips`): a toned syllable
   whose keys spell a valid reading in slot order (initial, medial, final)
   stays an option next to its clean splits, priced as a transposition (4),
   so words decide (方便 beats 方一半; a lone 一 + 半ˋ stays 一半). Toned
   syllables only. Rerun: swap-5 0.43 / 1.55 → 0.53 / 1.11 (libchewing
   0.52 / 1.37), 81 inputs better, 0 worse, every other config unchanged;
   ~1 ms more per swap-5 input. `RepairStrengthSweepTests` (real lexicon,
   toned, standard): 37.3% → 42.5% top-1 at 10% slips, no clean losses.
2. **A dropped key that leaves only an initial** — 9 losses, all to the
   `fuzzy` engine. 週 typed as ㄓ decodes as 字/之, 書 as ㄕ gives 師, 今 as ㄐ
   gives 機: Misstype reads the bare initial as a complete syllable, the
   prefix lookup finds 週末, 書, 今天 within the phrase.
3. **Clean-input misses only Misstype has** — 很晚才睡 → 很晚財稅, 手機快沒電
   → 手機快沒店 (libchewing gets both). Lexicon/scoring, not repair.
   Shared misses (要交 → 要教, 預訂 → 預定) are homophone preferences.

## Subjective (manual, macOS)

See `feel_protocol.md`.
