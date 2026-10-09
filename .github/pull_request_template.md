<!--
Read CONTRIBUTING.md first. Solve one underlying problem per PR.
Title: conventional commit in plain language, e.g. "fix(core): tone-less 3rd tone no longer outranks exact match".
Scopes: core, macos, linux, touch, english, site, wasm, tools, docs, ci.
Privacy: no real typed text or raw traces. Use synthetic or redacted input only.
-->

## Problem

<!-- One or two sentences. Expected vs actual behavior. Give a reproduction a
reviewer can run, ideally a key sequence:
  misstype-dev --session-trace 'su3cl3' --show
or a `--decode` input, a fixture, or exact UI steps. -->

## Change

<!-- How this fixes it, and which layer it touches (capture, phonetic
normalization, decoding, session, platform adapter). Editing rules belong in the
Zig `Session`; adapters only translate keys and draw. Split independent fixes. -->

## Scope and approval

<!-- Link the related issue or discussion if there is one. For a large feature or
a user-visible behavior change, discuss it first. Small fixes need no link. -->

## Verification

<!-- What you ran and what you observed, for the changed behavior. "Tests pass"
alone is not enough. State anything you could not check (e.g. no Linux box, no GUI).

Tick what applies and paste the key numbers/output:
- [ ] Focused test or replay fixture added/updated for the bug or behavior
- [ ] `cd core-zig && "$(../script/zig/bootstrap.sh)" build test`
- [ ] Decoder change: before/after candidates, quality and latency, offline or LLM-assisted
- [ ] Core behavior change: golden files regenerated and reviewed (`docs/zig-port.md`); Linux conformance (C1–C15) still passes
- [ ] Adapter/UI change: before/after screenshots; short recording if timing or motion matters
- [ ] New user-visible strings go through `L()`; `tools/check_localizations.py` passes
- [ ] Docs updated (architecture / decision record) if a boundary or contract changed

Upload screenshots and recordings to GitHub and embed them here.
Never commit PR-only assets. -->

## AI assistance

<!-- Required if an agent wrote or substantially shaped this change.
Model and harness, e.g. "Claude Sonnet 5.5 via Claude Code".
Confirm a human read every line and ran the verification above. -->
