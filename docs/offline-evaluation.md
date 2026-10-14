# Reserved external evaluation v1

Freeze this selection before testing a new offline word model. The existing
typing dev/holdout sets remain useful for diagnosis and regression checks;
neither is an unseen test after repeated development campaigns.

`tools/eval/external_v1.json` pins an existing public Common Voice 25 zh-TW
validated-sentence cache, the pronunciation lexicon, synthetic corpus and
200 selected sentence IDs/text/reading hashes. `tools/reserve_eval.py`
does not run a decoder or inspect candidate quality. It sorts unique,
dictionary-readable, pure-Han sentences of 4-16 characters by source ID,
excludes the first 2,000 (a conservative superset of the earlier short-text
evaluation prefix), and excludes all sentences in the known synthetic
typing/cursor batteries. The remaining pool is sampled by a fixed salted
SHA-256 of the text. Duplicate text under another ID cannot re-enter.

Regenerate locally from the same cached public data:

```sh
python3 tools/reserve_eval.py
```

The source is `~/.cache/misstype/cv/validated_sentences.tsv` (the public CC0
cache already used by `tools/bigram_eval.py`); `--source` can relocate it.
No download, personal data or network service is involved. The generated
TSV is `.cache/eval-reserve/external-v1.tsv`, not a committed artifact.
An existing manifest must match exactly; a new selection requires a new
named version, rather than silently overwriting the old sample.

For a future model comparison, freeze the model, global weights and binary
before examining this set's results. Replay the same seeded clean, toneless,
partial-tone and noisy typing through the real Zig Session on both versions.
Report fewer/more picks, unreachable sentences, clean-control accuracy and
per-key latency by persona. Any newly uncorrectable case or loss in a clean
control blocks promotion pending diagnosis. Do not tune on this set after
examining its failures: move consumed cases into regression coverage and
reserve a new version for a subsequent model choice.

Limitations: this is fresh text for our parameter-selection workflow, not
real key/tap logs. Pronunciations are inferred from the pinned dictionary
and have not been manually checked. Verbatim overlap with HPLT training
has not been checked. The source is short spoken-style text, so it does
not validate long compositions, mixed English, or personal-learning
transfer. Those remain separate checks. The manifest records these limits;
do not describe this as an independent human-typing or training-clean test.
