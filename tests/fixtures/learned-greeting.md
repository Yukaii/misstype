# Partial-tone greeting investigation (2026-10-13)

Hypothesis: learned word/context bonuses, keyed without tones, can explain
the reported `0 0sucl` → 暗暗你好 and `0 0 sucl` → 安安逆好.
The smallest falsification experiment is to replay both with and without
the synthetic `learned-greeting.json`; it contains no actual user data.

After building the Zig dev CLI, run from the repository root with shipping
resources (the default is `dist/MisstypeIME.app/Contents/Resources`):

```sh
core-zig/zig-out/bin/misstype-dev --session-trace '0 0sucl' --show
core-zig/zig-out/bin/misstype-dev --session-trace '0 0 sucl' --show
core-zig/zig-out/bin/misstype-dev --session-trace '0 0sucl' --show --user-lexicon tests/fixtures/learned-greeting.json
core-zig/zig-out/bin/misstype-dev --session-trace '0 0 sucl' --show --user-lexicon tests/fixtures/learned-greeting.json
```

Observed at `800812f`: without learned state, both finish as 安安你好;
with this synthetic state, the respective results are 暗暗你好 and 安安逆好.
Disabling the homophone table (`MISSTYPE_NO_HOMOPHONE=1`) leaves the
unlearned results unchanged. These are entirely offline replays.

The first tone mismatch costs 4 nats, whereas a first learned pick adds 6;
a second explicit first tone adds another mismatch cost, letting 安安 win
again. The learned context rule then promotes 逆 after 安安. This demonstrates
a sufficient cause, not confirmation that the reporter has these entries.
The reporter subsequently confirmed that 暗暗 had been learned. The fix
withholds learned word/context bonuses when any explicit tone in that word
disagrees with its dictionary reading. With the synthetic state above, both
inputs now finish as 安安逆好: the toneless 逆 context preference still applies.
With only the 暗暗 entry, both finish as 安安你好. `0 0 su3cl` also finishes as
安安你好 with both entries, because the explicit third tone excludes the
learned 逆 bonus. Unit tests cover partially toned words, maximum learning
bonus, context rules, toneless retyping and key repairs with matching tones.

Validation: native `zig build test` and the Linux all-layer suite passed
(core Debug/ReleaseFast, C ABI, fcitx5 C1–C15, IBus). Exact decode and
key/touch parity golden gates matched their existing outputs. The six
synthetic learned-state replays above took about 1.0–1.2 ms mean per key
(max 2.7 ms) with the native Debug build, ten repetitions per case; this
is a short greeting measurement, not a broad latency comparison.
Both 100- and 400-case session replay seeds (1 and 487) were regenerated and reviewed:
candidate/preedit changes reflect the new tone gate; committed text is
identical to the previous transcripts in both runs. The native replay shell
wrapper could not load the dylib because macOS strips `DYLD_LIBRARY_PATH`
when launching shell scripts; invoking the same replay executable directly
with that environment completed both runs successfully.
