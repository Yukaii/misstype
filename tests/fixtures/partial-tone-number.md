# A valid tone-closed run can contain two syllables

Synthetic replay from `tools/eval/typing_corpus.tsv`, persona
`clean-partial-tones`, seed 0:

```sh
core-zig/zig-out/bin/misstype-dev --session-trace 'w8rupsu0-4gj3njo' --show
core-zig/zig-out/bin/misstype-dev --session-trace 'g-m,-4gj3b4' --show
core-zig/zig-out/bin/misstype-dev --decode '-4gj3' --align
```

Expected: 他今年二十五歲, 十二月二十五日, 二十五. The tone after 十
is omitted; the third-tone key belongs to 五. At `4d5c1fd`, the first
two sessions finish as 他今年二屬歲 / 十二月二數日 and the panel cannot
recover the expected text. Whole-input decoding ranks 二屬 first and
does not produce 二十五: `gj3` is already the valid syllable ㄕㄨˇ,
so `repairComplete` never tries ㄕ + ㄨˇ.

Hypothesis: preserve the atomic syllable, but also admit an apical initial
(ㄓㄔㄕㄖㄗㄘㄙ) plus its remaining keys when an existing dictionary word
supports both syllables without a key or tone repair. The supplied tone
stays on the tail. Ordinary vowel combinations keep their current behavior.
The smallest falsification is the two replays above, followed by the existing
dev typing battery: reject an increase in correction cost or a loss of the
clean fully toned control. Check holdout only after fixing the rule on dev.

Use shipping resources (`--resources DIR` or `MISSTYPE_RESOURCES`), including
the current `homophone.bin`. These commands use no personal dictionary or
learning store. The core tests use a small synthetic lexicon and cover strict
tones, fuzzy repair off, the surviving atomic candidate, a first-tone 書,
fully toned and toneless 二十五, and the Session commit path.

After the change, both sessions finish with the expected text and require
no selection. Whole-input 二十五 is first (-11.493356, zero repairs and
unresolved syllables); 二屬 remains second at its original -16.100515.
`MISSTYPE_NO_TONE_RUN_SPLITS=1` restores the old behavior for comparison.
The 7,200-case before/after battery needs fewer picks in these two cases
and more in none; holdout has no selection-cost changes. Learning-transfer
failures elsewhere remain open (see the project outline).
