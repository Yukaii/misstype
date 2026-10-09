# Development guide

This repository is an experimental input device and decoder. The current goal is to validate the interaction model before committing to custom hardware.

## Current state (2026-10-09)

- The macOS Zhuyin IME (Zig core + IMK adapter) is approaching
  daily-usable: live conversion, syllable cursor, candidate window, learning,
  a user dictionary (Shift+←/→ marks a phrase, Return files it;
  `user_dictionary.tsv`, Settings editor on macOS), chunked auto-commit. The
  Linux fcitx5 port is actively maintained and held to the same conformance
  scenarios (C1–C15, `docs/cross-platform.md`); a behavior change in the core
  is not done until Linux still passes.
- Keyboard fuzzy matching is edit repair (transpose, neighbor/phonetic
  substitution, insert/delete, tone tolerance), costed against exact input.
  The coordinate-aware **touch** fuzzy layer — distance-weighted neighbor
  hypotheses from raw `(x, y)`, the `full-split-1` layout, `tools/noise.py`
  measurements (project outline, M3) — has a v1 in `core-zig/src/touch.zig`
  (2026-10-04, ported to Zig 2026-10-08): on the real lexicon it beats
  keyboard repair by +15 to +45 pp at jitter 0.08–0.12 without touching
  exact input; the lattice version (spatial costs inside each syllable's
  reading options) adds +30 to +40 pp over the first beam version on 11+ tap
  phrases. Break-even vs a keyboard is computed (touch must spread within
  ~0.07–0.10 of key centre); the human tap-spread measurement is missing.
  Open: that measurement, then wiring a touch surface to the session.
- Mixed Chinese/English with no mode switch has a measured v1
  (`core-zig/src/english.zig`, 2026-10-04): English words and one-letter
  typos are recognized from bare keys with no false switches on 600
  pure-Chinese inputs (English list: pinned FrequencyWords, CC BY-SA, see
  `third_party/FrequencyWords/LICENSE.md`) and is wired into the session
  (`mixedEnglish`, macOS default off): clean English is adopted 92%, 0% of
  pure Chinese is. Cost is no longer open (Zig, 2026-10-09:
  toneless mixed input 4.5 ms mean / 21 ms max per key, +2 ms over off;
  `tools/mixed_latency.py`; Swift was ~110-130 ms); real-typing
  quality is unmeasured. Python remains the reference for the touch
  semantics only; the "do not port" rule below applies to everything else.

- **The core is Zig** (`core-zig/`, pinned Zig 0.17.0 via
  `script/zig/bootstrap.sh`) and is the single implementation on every
  platform: Linux fcitx5 and the macOS IMK adapter use its C ABI
  (`Sources/CMisstype/include/misstype.h`), and the site demo and video
  renderer use its wasm32-wasi build (`zig build wasm`). The Swift
  `MisstypeCore`, its C ABI and CLI were retired on 2026-10-09 after a
  differential campaign (bit-identical candidates, scores and session
  transcripts, see `docs/zig-port.md`). Swift remains only on macOS for
  the IMK adapter, the Settings UI, the installer and the Carbon source
  tool; it holds no editing or decoding rules (`MisstypeMacKit` has the
  UI-side types). The Swift reference's outputs are frozen as golden files
  under `tests/golden/`; a behavior change is intentional only when the
  golden files are regenerated and reviewed (`docs/zig-port.md`).

- macOS packaging is verified on a Mac (2026-10-04, macOS 27) except a few
  GUI paths: a per-user installer app in a DMG, Sparkle 2 updates from GitHub
  Releases, signed and notarized by `release.yml` (dispatch run, Gatekeeper
  accepts the quarantined DMG). The sandboxed IME updates itself in place,
  and bad signatures/keys are refused. First public release: v0.0.1 (2026-10-04, DMG 4.4 MB).
  Design, results and what is still unchecked: `docs/release.md`.

## Product constraints

- Capture first, decode later. The input path must not force candidate selection or correction while the user is composing.
- Keep the raw trace. Rendered Chinese is a reconstruction and must never replace the original touch/key/phonetic evidence.
- Chinese input is phonetic-first. Bopomofo (Zhuyin) is a first-class mode; English and mixed Chinese/English text are also required.
- Offline behavior is the baseline. A local deterministic decoder should remain useful when no model, network, or API key is available.
- Do not add hardware dependencies until the touchscreen prototype demonstrates a measurable benefit over a conventional keyboard.

## Working loop

1. Read `docs/project-outline.md` and `docs/architecture.md` before changing behavior.
2. Write down the hypothesis and the smallest experiment that can falsify it.
3. Keep changes in one layer where possible: capture, phonetic normalization, decoding, or platform adapter.
4. Preserve replayable fixtures. Every bug found from an input trace should become a fixture without storing unnecessary personal text.
5. Run the fastest relevant checks after each change, then the full test suite before merging.
6. For decoder changes, report latency, candidate quality, and whether the result came from offline or LLM-assisted decoding.
7. Update the architecture or decision record when a boundary, data contract, or user-visible behavior changes.

## Data and privacy

- Treat raw traces and typed text as sensitive local data.
- Do not send input to a remote service by default. Remote LLM use must be explicit, replaceable, and clearly observable in development logs.
- Use synthetic or redacted fixtures in the repository.
- Do not commit API keys, personal traces, generated model caches, or build artifacts.

## Definition of done

A change is ready when its behavior is covered by a replayable test or documented manual check, the relevant command has passed, and the docs describe any new assumption or limitation. Prefer small reversible changes over speculative abstractions.

## Canonical commands

The Zig core (`core-zig/`) is the single source of truth for decoding and
editing behavior. The Python package (`src/misstype`, Python 3.11+, no
runtime dependencies) is the capture/touch prototype slated for replacement;
do not port decoder changes to it. Its checks still run:

```sh
PYTHONPATH=src python -m unittest discover -s tests -v
PYTHONPATH=src python -m misstype.cli examples/hello.jsonl
```

Core checks (any host; the first run downloads the pinned Zig):

```sh
cd core-zig && "$(../script/zig/bootstrap.sh)" build test   # unit + behavior suites
python3 tests/capi/ctl_test.py core-zig/zig-out/bin/misstypectl   # after `zig build`
core-zig/bench/compare.sh && core-zig/bench/parity.sh && core-zig/bench/replay.sh   # golden gates
```

The macOS IME target is package-first SwiftPM; `swift test` covers the
UI-side `MisstypeMacKit` types:

```sh
./script/zig/build_macos.sh   # universal libMisstypeCAPI.dylib the IME links
swift test
./script/build_and_run.sh --build-only
./script/install_ime.sh
```

Linux, all layers (core tests, C ABI smoke test, fcitx5 headless suite), in
Docker or bare-metal:

```sh
script/linux/dev.sh 'bash script/linux/test_all.sh'
bash script/linux/test_all.sh   # on a provisioned Linux box
script/linux/install_ime.sh     # build + install on this desktop, restart fcitx5
```

Linux also ships `misstypectl` (Zig, `core-zig/src/ctl.zig`: `dict` and
`config` subcommands) and a GTK4 dictionary editor over it; the fcitx5
settings page and `misstypectl config` edit the same `conf/misstype.conf`
(`docs/linux-port.md`, L7). Keep the key lists in Zig `ctl.settings` in step
with `MisstypeConfig` in `linux/fcitx5/src/engine.cpp`. `misstype-dev`
(`core-zig/src/dev.zig`) is the offline decode / session-trace / cursor-replay
CLI the `tools/*.py` measurement scripts drive.

Editing rules live in the Zig `Session` (`core-zig/src/session.zig`);
platform adapters only translate key events and draw the view (see
`docs/architecture.md`, Platform boundary). The wasm build is checked by
`tests/wasm_test.mjs` (CI job `wasm`).

Platform adapters follow `docs/cross-platform.md` (contract + conformance
scenarios C1–C15). Linux work follows `docs/linux-port.md`; run Linux
commands through `script/linux/dev.sh '<cmd>'` (Docker, `linux/Dockerfile`).

Adapter lessons that cost time once (keep them): send marked text to IMK as
an `NSAttributedString` with underline + `markedClauseSegment`, never a bare
String — otherwise some clients draw no caret/selection and a self-drawn
cursor in the candidate panel ends up papering over it. The candidate window
shows rows only. User-visible UI strings go through `L()` and
`tools/check_localizations.py`.

`script/prepare_lexicon.py` downloads only the pinned public dictionary sources
listed in `third_party/*/sources.json` (McBopomofo, NAER); it must never
receive user input. Do not commit `.cache/`, `.build/`, or `dist/` artifacts.

Use scripts under `tools/` for deterministic replay and measurement rather than ad-hoc notebooks. Keep these commands runnable from the repository root when the implementation language changes.

## Releases

- Release tags use `vMAJOR.MINOR.PATCH`. Commit and push the intended changes
  before tagging; an annotated tag at the intended HEAD followed by
  `git push origin <tag>` automatically runs `.github/workflows/release.yml`.
  CI runs `swift test`, packages the universal macOS DMG and update ZIP,
  signs/notarizes when the configured secrets exist, and publishes the GitHub
  Release, checksums, and Sparkle appcast. No local packaging is needed just
  to cut a release. See `docs/release.md` for signing prerequisites.
- Once the repository is public, Release also attests the final DMG, update
  ZIP, checksums, and optional appcast with GitHub/Sigstore build provenance, and includes
  `build-provenance.sigstore.json` for verification. All assets are uploaded
  to a draft before publishing locks the immutable release. Never overwrite
  published assets or move a release tag; fixes need a new version.
  Native attestations are unavailable for this user-owned private repository:
  while private, CI skips attestation and notes this in its summary. Keep the
  repository private until the maintainer explicitly requests publication;
  attestation enables automatically on new runs after it becomes public.
- For the normal automated path, run **Actions → Tag release → Run workflow**
  and select `major`, `minor`, or `patch` (default `patch`), or use
  `gh workflow run tag-release.yml --ref main -f bump=minor`.
  This tags the current remote `main` HEAD, using the numerically highest
  stable version tag as its baseline; lower components reset on major/minor
  bumps, and prerelease tags do not set the baseline. Existing tags are never
  force-pushed. Publish jobs build the exact new tag.
- The tag workflow uses `GITHUB_TOKEN`, whose tag pushes do not trigger a
  second workflow run. It therefore explicitly dispatches the existing
  Release workflow at the new tag with `publish=true`; no additional PAT is
  needed. Keeping builds in Release preserves its increasing run number for
  Sparkle. Direct manual dispatch of **Release** is artifact-only by default;
  publishing requires its `publish` checkbox, dispatching at the existing
  version tag (`--ref <tag>`), and `version=<tag>`. Checkout must match
  `github.sha` so the attestation identifies the actual build source.
- Treat this flow as the documented contract rather than rediscovering it
  for every release. Check that the requested version is unused and verify
  the resulting workflow status; inspect workflow internals when changing
  them or diagnosing a failure. Report the tag, commit, and Actions URL.
