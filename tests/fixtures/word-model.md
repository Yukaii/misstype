# Full word model prototype: replay and limits

Synthetic ranking fixture (no user text): the lexicon has `ㄋㄧˇ 你 -5` and
`ㄋㄧˇ 妳 -6`. Training has one sentence `你` and nine sentences `妳`, each
with BOS/EOS. `core-zig/src/tests/core_test.zig` replays `su3`: baseline and
model weight 0 give `你` with identical scores; weight 0.5 gives `妳`.
`word_lm.zig` checks conditional normalization, unseen-word/history backoff,
truncation and invalid discounts against these complete toy counts.

The real pilot is generated locally, never bundled. Reproduction:

```sh
python3 -m venv .cache/wordlm-venv
.cache/wordlm-venv/bin/python -m pip install pyarrow
.cache/wordlm-venv/bin/python tools/word_lm.py
(cd core-zig && "$(../script/zig/bootstrap.sh)" build -Doptimize=ReleaseFast)
mkdir -p .cache/wordlm/bin
cp core-zig/zig-out/bin/misstype-dev .cache/wordlm/bin/
python3 tools/eval_word_lm.py --bin .cache/wordlm/bin/misstype-dev
```

The builder reads only four existing, hash-pinned HPLT shards and the existing
pinned segmentation lexicon (`third_party/HPLT/sources.json`); it never downloads
text or reads typing traces. Each shard contributes its first 10,000 documents.
The model includes singleton pairs, BOS/EOS/UNK and unseen dictionary words.
Absolute discount is 0.75; unigram smoothing is 1. Model/source hashes are saved
beside the binary; `eval_word_lm.py` writes its fixed-weight protocol before
running the real Session. Model defaults and old typing baselines stay unchanged.
The weights 0.1/0.25/0.5 are development choices, not independent test results.

Limitations: dictionary-DP segmentation inherits lexicon bias; the leading
40,000 web documents are not a random sample. Train/dev and train/reserved-text
contamination has not been audited. BOS is used for interactive prefixes;
there is no EOS score at every prefix. Word-model scores are interpolated with
heuristic dictionary scores, not a second normalized distribution. Existing
beam/entry caps can omit the correct candidate. The full counts are deliberately
large; capacity/startup improvements require a separate quality-preserving
experiment. The reserved 200 external sentences remain sealed until dev guards
pass; this fixture contains no results from them.

## Partial-tone correction regression before the positional pin fix (weight 0.5)

Synthetic dev case `zh|partial-tones|1|公車還沒來` omits the `/` from 公.
Replay keys: `ej tk c96ao6x96`. The spaces are first-tone keys.

```sh
core-zig/zig-out/bin/misstype-dev --session-trace 'ej tk c96ao6x96' --show
MISSTYPE_WORD_LM="$PWD/.cache/wordlm/pilot.bin" MISSTYPE_WORD_LM_WEIGHT=0.5 \
  core-zig/zig-out/bin/misstype-dev --session-trace 'ej tk c96ao6x96' --show
```

The full `--decode` comparison gives:

| Model | First candidate | Score | Correct candidate |
| --- | --- | ---: | --- |
| Off | 公車還沒來 | -33.318245 | first, one repair |
| Weight 0.5 | 估車還沒來 | -32.361463 | second, -33.417141, one repair |

The actual typing evaluator finishes `公車還沒來` with the baseline, but its
normal correction traversal cannot recover this sentence with the model
(`before_fix` and `final` both `估車還沒來`). A correct full-phrase candidate
therefore does not guarantee recoverability through Session's word choices.
This fixture records the gap; it does not attribute it to a particular search
branch without a Session investigation. A second partial-tone regression uses
`2jo41jfu3，jit42l4xk7。` for `對不起，我遲到了。`; baseline corrects `赤道`
where the model's `握到了` remains uncorrectable. One other case becomes
recoverable, leaving this persona's uncorrectable total 44 → 45.


The positional pin fix is covered without the large model in `core_test.zig`
and `caret_test.zig`. With that fix, the normal Session corrector recovers
`公車還沒來`: the listed repair is now honored against its captured reading.
The `對不起，我遲到了。` case still fails with weight 0.5; do not remove this
fixture or interpret the pin fix as resolving every segmentation regression.
Current paired results and replay changes: `docs/repair-pick.md`.


## Punctuation menu hides an available alternative split

The `對不起，我遲到了。` case is recoverable in the unchanged core. Immediately
following the period, the view lists punctuation choices. Escape closes that
menu and reveals the sentence rows, with the correct four-syllable alternative
third. Replay `2jo41jfu3，jit42l4xk7。⎋↓d` at weight 0.5 and Return commits the
expected sentence. The native corrector now performs that Escape instead of
mistaking the punctuation rows for sentence rows. Two small, model-independent
regression tests live in `core-zig/src/dev.zig`, run by `zig build test`.
See `docs/punctuation-correction.md`; earlier failure results above are historical.
