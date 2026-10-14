# Partial-tone sentence investigation (2026-10-14)

Minimal, non-personal phrase: `1jg45k4u;187` should finish as 不是這樣吧.
Reported result: 不識之無樣吧. The keys omit the tone after 不 and 樣;
the final neutral tone closes the fused 樣吧 run.

Hypothesis: tone-run segmentation loses 這 or splits 樣 while expanding
the final run. The smallest falsification experiment compares whole-input
decoding with per-key session replay, without persistent state:

```sh
core-zig/zig-out/bin/misstype-dev --decode '1jg45k4u;187' --align
core-zig/zig-out/bin/misstype-dev --session-trace '1jg45k4u;187' --show
```

Use shipping resources (the default is
`dist/MisstypeIME.app/Contents/Resources`), or pass `--resources DIR`.
These commands read no personal learning files and perform no network calls.

Observed at `5edeac0`: both paths produce 不是這樣吧. Whole-input decoding
without the optional homophone table ranks it first with zero repairs and
zero unresolved syllables. With the shipping table, the session shows
不是這 at key 7, 不是這樣 at key 9, and 不是這樣吧 at key 12.
Direct C ABI replay against the installed macOS library also produces
不是這樣吧 at all four repair strengths (off, light, standard, strong).
The installed app's headless `--session-trace` (through `ZigSessionAdapter`)
also finishes as 不是這樣吧. The reporter confirmed installation from
`5edeac0` with `script/install_ime.sh`, and supplied a screenshot showing
personal typing-slip learning enabled with learned substitution pairs.
External probes cannot read the protected container's channel model:
loading it silently falls back to an empty model (zero pairs). These probes
therefore do not establish that the personal model is harmless. A controlled
manual comparison is to disable typing-slip learning, clear the composition
with Escape, and type the same keys again, preserving the stored model.
The fresh CLI session with shipping resources takes roughly 0.5–9 ms per
key in the local Debug build; this is a short replay, not a latency benchmark.

The reporter clarified that the failure persists with typing-slip learning
disabled and with **all tones omitted**: `1jg5ku;18`. This distinction
reproduces the failure through the installed app's headless session adapter
when its user dictionary is explicitly loaded and repair strength is strong.
Both word learning and channel learning can be disabled; neither is necessary.
The protected user dictionary is read only by the installed app and copied
to its temporary trace directory. Its contents are not included here.

Controlled results on `5edeac0`, same dictionary and both learning flags off:

| Repair strength | `1jg5ku;18` (no tones) | `1jg45k4u;187` (partial tones) |
| --- | --- | --- |
| off | 不是這樣吧 | 不是這樣吧 |
| light | 不是這樣吧 | 不是這樣吧 |
| standard | 不是這樣吧 | 不是這樣吧 |
| strong | 不識之無樣把 | 不是這樣吧 |

To reproduce, use the installed app executable with `--session-trace KEYS
--show --user-dictionary PATH -MisstypeRepairStrength strong
-MisstypeUserLearning NO -MisstypeChannelLearning NO`. The `-Misstype…`
arguments are process-local UserDefaults overrides; they do not change the
running IME's preferences. Compare with `-MisstypeRepairStrength standard`.

Strong allows repairs of valid readings inside words; user dictionary words
default to weight 0, above built-in scores. Their interaction allows the
unwanted repaired path to outrank exact text. The specific dictionary entry
responsible has not been isolated into a synthetic fixture. No decoding rule
has been changed. Standard strength is a verified workaround for this case.
Keep personal dictionary entries, learned state and surrounding text out of
repository fixtures.

## Isolated and fixed (2026-10-14)

The responsible entry is the idiom 不識之無 (`ㄅㄨˋ-ㄕˋ-ㄓ-ㄨˊ`), which is
not in the built-in lexicon. A synthetic dictionary holding only that line
reproduces the table above with `core-zig/zig-out/bin/misstype-dev`
(`--repair-strength` was added to the developer CLI for this):

```sh
printf '不識之無 ㄅㄨˋ-ㄕˋ-ㄓ-ㄨˊ\n' > /tmp/dict.tsv
core-zig/zig-out/bin/misstype-dev --session-trace '1jg5ku;18' --show \
    --repair-strength strong --user-dictionary /tmp/dict.tsv
```

Mechanism: toneless `5k` (ㄓㄜ) also segments as the two real syllables
ㄓ + ㄜ; strong repairs the valid ㄜ to its neighbor ㄨ (`k`→`j`, 5.0) and
the user word's weight 0 outweighs the exact path by about 15 nats.
Without the dictionary, or at standard, the result was already correct.

Rule: a repair of an already valid reading never lands on a user
dictionary word, in both the decoder search and the cursor word lists.
All four strength × input combinations now finish as 不是這樣吧; typing
the word's own reading (`1jg5j`) still gives 不識之無. Regression test:
`strong does not repair a valid reading onto a user dictionary word`
(`core-zig/src/tests/repair_test.zig`).
