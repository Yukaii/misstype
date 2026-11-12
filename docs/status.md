# Status

Where the project stands and what is open, in the order it should be taken.
Dated; update the date and the affected bullet when a change lands. Rules
for working in the repository live in `AGENTS.md`; goals and milestones in
[`project-outline.md`](project-outline.md); experiments and measurements in
[`lab-notebook.md`](lab-notebook.md).

Last reviewed: 2026-11-12 (latest release v0.5.5, 2026-10-14).

## Platforms

- **macOS IME** (Zig core + IMK adapter): daily-usable. Live conversion,
  syllable cursor (Return ends the walk in one press, Cmd+←/→ jump to
  the first word / back to the end, grid columns on ←/→ once the keys are
  armed; 2026-11-12), candidate window, learning, a user dictionary
  (Shift+←/→ marks a phrase, Return files it; `user_dictionary.tsv`,
  Settings editor), chunked auto-commit, AppKit Settings with themes and a
  learned-phrase manager (2026-10-12). Packaging is verified on a Mac
  (2026-10-04, macOS 27) except a few GUI paths: per-user installer app in a
  DMG, Sparkle 2 updates from GitHub Releases, signed and notarized by
  `release.yml`; the sandboxed IME updates itself in place and refuses bad
  signatures. Design and what is unchecked: [`release.md`](release.md).
- **Linux**: fcitx5 addon and IBus engine (2026-10-10), both held to the
  conformance scenarios C1–C15 ([`cross-platform.md`](cross-platform.md));
  a core behavior change is not done until Linux still passes. Native
  packages for Ubuntu 24.04, Fedora 43 and Arch (x86_64, aarch64), AUR
  `-git` and release-pinned `-bin` packages (2026-10-11/12). `misstypectl`
  and a GTK4 dictionary editor; settings shared with `misstypectl config`
  ([`linux-port.md`](linux-port.md)). Open: L6 desktop acceptance in a real
  session.
- **Web**: the landing page demo and a web editor (site/, Vite): notes with
  folders, per-note and per-workspace CRDT merging, sync to Dropbox or
  Google Drive (2026-11-01/03), an on-screen Zhuyin keyboard for touch
  devices, PWA. Design: [`editor.md`](editor.md). The npm package
  `misstype-wasm` (drop-in `enable` layer, host hooks) and an Obsidian plugin
  (desktop and mobile, 2026-10-25) use the same binding.
- **Windows**: TSF port sketched ([`windows-port.md`](windows-port.md)), paused
  until a Windows machine is available.

## Core

- **The core is Zig** (`core-zig/`, pinned Zig 0.17.0 via
  `script/zig/bootstrap.sh`), the single implementation everywhere. Native
  adapters link its C ABI (`Sources/CMisstype/include/misstype.h`); the
  WebAssembly module is the same ABI compiled for wasm32-wasi (ABI v3,
  2026-11-11), used through `packages/misstype-wasm` by the site, the video
  renderer and the Obsidian plugin. The Swift core was retired on 2026-10-09
  after a differential campaign ([`zig-port.md`](zig-port.md)); its outputs are
  frozen as golden files under `tests/golden/`. The Python prototype was
  retired on 2026-11-11; the tools under `tools/` drive `misstype-dev`.
- **Keyboard fuzzy matching** is edit repair (transpose, neighbor/phonetic
  substitution, insert/delete, tone tolerance) costed against exact input,
  with a user-chosen repair strength and an optional learned per-user
  channel model. Context: toneless input reranks by context (2026-10-14),
  an experimental homophone word-bigram table ships on every platform, and
  learned picks reorder words but never choose the syllable split.
  End-to-end quality is measured by `tools/typing_eval.py` (seeded typist
  personas through the real `Session`) against a checked-in baseline.
- **Touch** (`core-zig/src/touch.zig`, `misstype-dev --touch`): on the real
  lexicon coordinate-aware decoding beats keyboard repair by 20–50 pp at
  jitter 0.10–0.12 without touching exact input (`tools/noise.py`,
  2026-11-11); the lattice version adds +30 to +40 pp over the first beam
  version on 11+ tap phrases. Break-even vs a keyboard: touch must spread
  within ~0.07–0.10 of key centre. **Open, in order:** measure human tap
  spread, then wire a touch surface to the session. No hardware until that
  shows a measurable benefit (product constraint).
- **Mixed Chinese/English** with no mode switch (`core-zig/src/english.zig`):
  English words and one-letter typos recognized from bare keys, no false
  switches on 600 pure-Chinese inputs; clean English adopted 92%, pure
  Chinese 0%. 4.5 ms mean / 21 ms max per key toneless
  (`tools/mixed_latency.py`). On by default in the browser binding, off by
  default on macOS. **Open:** real-typing quality.

## Engineering

- CI runs the macOS job only when Swift-side inputs change and skips repeat
  suites on squash merges whose tree already passed as a PR
  (`script/ci/plan.sh`); `script/check.sh` runs the same layer mapping
  locally. Releases: `vMAJOR.MINOR.PATCH` via the Tag release workflow
  (`AGENTS.md`, Releases).
- The repository is private; attestation enables itself once public.

## Next, in order

1. Human tap-spread measurement for the touch layer, then a touch surface
   wired to the session (the project's main hypothesis).
2. Linux L6 desktop acceptance in a real fcitx5 and IBus session.
3. Real-typing quality of mixed Chinese/English (consented sessions kept
   outside the repository).
4. Windows TSF port, once a Windows machine is available.
