# Development guide

This repository is an experimental input device and decoder. The current goal is to validate the interaction model before committing to custom hardware.

## Where things stand

Read [`docs/status.md`](docs/status.md) first: platforms, what is open and
in which order (dated). Goals and milestones: `docs/project-outline.md`;
dated experiments and measurements: `docs/lab-notebook.md`. When a change
lands that moves the state (a platform gains a feature, an open item
closes, a measurement replaces a guess), update the matching bullet in
`docs/status.md` in the same PR. This file holds only rules that rarely
change.

Rules that outlive any status:

- The Zig core (`core-zig/`) is the single implementation on every platform.
  Native adapters link its C ABI (`Sources/CMisstype/include/misstype.h`);
  the WebAssembly module is that same ABI compiled for wasm32-wasi, used
  through `packages/misstype-wasm`. Adding a capability means adding it to
  the C ABI once; there is no browser-only API.
- A core behavior change is intentional only when the golden files under
  `tests/golden/` are regenerated and reviewed (`docs/zig-port.md`), and it
  is not done until Linux still passes the conformance scenarios C1–C15
  (`docs/cross-platform.md`).

## Product constraints

- Capture first, decode later. The input path must not force candidate selection or correction while the user is composing.
- Keep the raw trace. Rendered Chinese is a reconstruction and must never replace the original touch/key/phonetic evidence.
- Chinese input is phonetic-first. Bopomofo (Zhuyin) is a first-class mode; English and mixed Chinese/English text are also required.
- Offline behavior is the baseline. A local deterministic decoder should remain useful when no model, network, or API key is available.
- Do not add hardware dependencies until the touchscreen prototype demonstrates a measurable benefit over a conventional keyboard.

## Working loop

1. Read `docs/status.md`, `docs/project-outline.md` and `docs/architecture.md` before changing behavior; check `docs/lab-notebook.md` for earlier experiments on the same question.
2. Write down the hypothesis and the smallest experiment that can falsify it.
3. Keep changes in one layer where possible: capture, phonetic normalization, decoding, or platform adapter.
4. Preserve replayable fixtures. Every bug found from an input trace should become a fixture without storing unnecessary personal text.
5. Before calling a change done, run `script/check.sh`: it picks the focused
   checks for the layers you touched (same path rules as CI,
   `script/ci/layers.sh`) and prints a pass/fail/skip summary. Fix every
   FAIL; report every skip you could not run. Add `--deep` for core decoder
   changes (golden gates, typing eval) and `--linux` for adapter changes.
6. For decoder changes, report latency, candidate quality, and whether the result came from offline or LLM-assisted decoding.
7. Update the architecture or decision record when a boundary, data contract, or user-visible behavior changes.

## Pull requests

Humans and agents follow `CONTRIBUTING.md` and `.github/pull_request_template.md`.
For agents:

- Open a PR only when the user explicitly asks. One request is one PR; split
  unrelated fixes. (Maintainer shortcut: small changes may still go straight
  to `main` when the user says so.)
- Title is a conventional commit in plain language, e.g.
  `fix(core): tone-less 3rd tone no longer outranks exact match`.
- Fill every template section. Problem and Change in your own words, short.
  Verification states what you ran and observed, not "tests pass".
- Give a reproduction a reviewer can replay: a `--session-trace` key sequence,
  `--decode` input, or fixture. Turn trace-derived bugs into fixtures with
  synthetic or redacted text.
- Run focused checks for the touched layer (see Canonical commands). Do not
  launch long repo-wide runs just to fill the checklist; CI runs the rest.
  Say what you could not run (no Linux box, no GUI session).
- UI or adapter changes: capture before/after screenshots, plus a short
  recording when timing or motion matters, using the preview/device tools
  when available. Ask before launching your own dev servers, browsers or GUI
  automation. Upload evidence to the PR; never commit it.
- Decoder changes: report candidates before/after, quality, latency and
  offline vs LLM-assisted.
- End the **AI assistance** section with the model and harness that did the
  work (e.g. "Claude Sonnet 5.5 via Claude Code").
- After creating a PR, report its URL and the checks that are still pending.

## Data and privacy

- Treat raw traces and typed text as sensitive local data.
- Do not send input to a remote service by default. Remote LLM use must be explicit, replaceable, and clearly observable in development logs.
- Use synthetic or redacted fixtures in the repository.
- Do not commit API keys, personal traces, generated model caches, or build artifacts.

## Definition of done

A change is ready when its behavior is covered by a replayable test or documented manual check, the relevant command has passed, and the docs describe any new assumption or limitation. Prefer small reversible changes over speculative abstractions.

## Canonical commands

The Zig core (`core-zig/`) is the single source of truth for decoding and
editing behavior. The Python capture/touch prototype was retired on
2026-11-11; the measurement tools under `tools/` (Python 3.11+, stdlib only)
drive `misstype-dev` through `tools/misstype_dev.py`, including touch
(`--touch`, `--touch-batch`, `--touch-layout`) and JSONL trace replay
(`tools/replay.py`, `tools/bench.py`). Their tests:

```sh
python3 -m unittest discover -s tests -v   # Zig-backed tests skip without a built misstype-dev
python3 tools/bench.py                     # JSONL fixtures through the real core
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

Linux, all layers (core tests, C ABI smoke test, fcitx5 and IBus headless suites), in
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
CLI the `tools/*.py` measurement scripts drive. End-to-end typing quality
(seeded typist personas, typos, mixed English, through the real `Session`)
is `python3 tools/typing_eval.py --baseline tools/baseline/typing_eval.json`
(ReleaseFast build; `docs/development.md`, 打字評估); behavior changes report
its FIXED/BROKEN and update the baseline when the change is intended.

Editing rules live in the Zig `Session` (`core-zig/src/session.zig`);
platform adapters only translate key events and draw the view (see
`docs/architecture.md`, Platform boundary). The wasm build is checked by
`tests/wasm_test.mjs` (CI job `wasm`).

Platform adapters follow `docs/cross-platform.md` (contract + conformance
scenarios C1–C15; platform priority and the Windows TSF and IBus sketches:
`docs/windows-port.md`, `docs/ibus-port.md`). Linux work follows `docs/linux-port.md`; run Linux
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
