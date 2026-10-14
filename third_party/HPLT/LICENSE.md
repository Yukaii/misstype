# HPLT 2.0 (zho_Hant) — attribution for `homophone.bin`

`Resources/homophone.bin` is a table of word-pair association statistics
computed from the Traditional Chinese part of the HPLT 2.0 cleaned corpus:
HPLT, *HPLT2.0_cleaned*, config `zho_Hant`, shards `train-00000` to
`train-00003` of 1722 (pinned with checksums in `sources.json`),
https://huggingface.co/datasets/HPLT/HPLT2.0_cleaned.

Cite: Burchell et al., "An Expanded Massive Multilingual Dataset for
High-Performance Language Technologies (HPLT)", ACL 2025 (the citation HPLT
asks for on the dataset card).

## What the corpus's terms say

Read from the dataset card on 2026-10-12:

- HPLT does not own the text the corpus was extracted from.
- HPLT licenses only the *packaging* of the data under CC0 1.0.
- Notice and take-down: a rights holder may write to
  hplt-datasets@ufal.mff.cuni.cz; HPLT removes the affected sources from its
  next release.
- Users are responsible for complying with the law that applies to their use
  (the card names the EU Copyright Directive 2019/790 and the GDPR).

So the CC0 grant covers HPLT's packaging, not the web pages inside it.

## What Misstype ships and how it is licensed

The file contains no corpus text. Each of its 300,000 entries is a 40-bit hash
of a pair of dictionary words (both from Misstype's own McBopomofo-derived
lexicon) and one signed byte, a quantized association strength. Neither the
sentences nor the pages can be reconstructed from it. The table is used only
to choose between homophones (自 / 字) that the decoder already considers
equally pronounced, including words that sound alike once no tone is typed
(喝 / 何).

Misstype asserts no rights over these aggregate statistics and dedicates
whatever rights it holds in `homophone.bin` to the public domain under
[CC0 1.0](https://creativecommons.org/publicdomain/zero/1.0/). This is
separate from the MIT license of Misstype's code. It makes no claim about the
web pages the counts were drawn from, which remain their owners'.

## Take-down

If HPLT removes sources, or a rights holder raises a legitimate objection,
the table is regenerated without the affected sources (the steps are in
`sources.json`) and a new version ships; the table is optional and the
decoder falls back to its unchanged behavior without it. Deleting
`homophone.bin` from an install turns the feature off.
