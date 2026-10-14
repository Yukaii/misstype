# A development gain that fails the post-selection regression check

Synthetic sentence from `tools/eval/typing_corpus.tsv`: 我先去洗澡.
Toneless keys: `jivu0fmvuyl`. Shipping resources, no personal state:

```sh
core-zig/zig-out/bin/misstype-dev --decode 'jivu0fmvuyl' --align
MISSTYPE_WORD_PENALTY=0.75 core-zig/zig-out/bin/misstype-dev --decode 'jivu0fmvuyl' --align
MISSTYPE_WORD_PENALTY=0.75 core-zig/zig-out/bin/misstype-dev --session-trace 'jivu0fmvuyl' --show
```

At `eb54da1`, default word penalty 0.5: 我先去洗澡 is first
(-33.250084, zero repairs), ahead of 我想去洗澡 (-33.489695, one
repair). Penalty 0.75: 我先取消 becomes first (-31.819092, one repair);
我想去洗澡 is -33.989695, and the exact input 我先去洗澡 is seventh
(-34.000084). The session also ends as 我先取消. Selection can restore
the target, but it now costs one pick instead of none.

The three-word exact path pays 0.75 more when the penalty increases;
the two-word 我想去洗澡 path pays 0.5 more. That reverses their margin.
`Lexicon.decodeComposition` opens additional repair segmentations when
the initial top candidate has a repair, so changing a language weight can
also change which hypotheses are searched. This is a plausible source of
the larger discontinuity, not a verified ablation of that search gate.

Protocol: nine fixed profiles, five sentence-grouped folds on Chinese dev.
All folds selected 0.75 with unchanged context weights, 18 fewer-pick
cases / 0 more. The subsequent existing holdout check (Chinese and mixed
English) had 55 fewer / 19 more, including this case and two newly
uncorrectable English cases. Clean-toneless no-pick fell 69.8 -> 68.5 %.
The candidate was rejected, default 0.5 retained, and no alternative was
selected using holdout. Existing holdout is a regression set, not a new
blind test. This fixture records the failure for later model/search work;
it is not a request to tune specifically for 洗澡.
