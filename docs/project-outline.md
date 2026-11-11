# Project outline

> Goals, milestones and open questions. Dated experiments and measurements
> live in [`lab-notebook.md`](lab-notebook.md); the current state and next
> steps in [`status.md`](status.md). Where this file names the Swift
> `MisstypeCore` (retired 2026-10-09) or the Python prototype package
> (retired 2026-11-11), it means implementations since replaced by the Zig
> core (`core-zig/`).

## Problem

Conventional touch keyboards make the user divide attention between composing and locating small, exact targets. Chinese input adds another interruption: choosing candidates while the thought is still forming. Misstype explores whether a forgiving split surface can preserve a user's learned hand motion and postpone linguistic decisions until a phrase is complete.

## Product thesis

Capture a continuous, timestamped trace of two-handed input. Interpret it as a phonetic stream with uncertainty, then decode the whole phrase. The user should be able to keep moving, pause, and receive a committed result without navigating a candidate list for every syllable.

## Scope for the first prototype

Included:

- Two independent virtual touch pads with configurable split layouts.
- Raw touch coordinates, pressure/contact state when available, timestamps, and explicit gesture boundaries.
- Zhuyin input, tone keys as optional syllable boundaries, English mode, and mixed-language spans.
- A delayed commit action and an inactivity timeout.
- Deterministic offline decoding with an optional local-model adapter.
- Trace replay, metrics, and side-by-side comparison with a conventional keyboard.

Deferred:

- Custom electronics, force sensors, haptics, and low-power firmware.
- System-wide IME integration.
- Cloud inference, accounts, sync, and social features. (Exception, 2026-10-25: the web editor syncs notes to the user's own Dropbox or Google Drive, opt-in and browser-direct; `docs/editor.md`, Cloud sync.)
- Automatic learning from personal text without an explicit opt-in and export path.

## Milestones

### M0 — Decoder seam

Feed a complete delayed phonetic stream into a decoder and emit one sentence. Use hand-authored fixtures first. This validates the core UX independently of touch hardware.

Exit: replay is deterministic; Chinese, English, and mixed fixtures produce an inspectable result; raw input remains available.

### M1 — Zhuyin capture *(prototype slice complete)*

The first keyboard adapter maps standard physical Zhuyin keys into phonetic tokens and attaches tone keys to the preceding symbol. The session coordinator now provides preview, explicit commit, pause commit, revision tracking, and model fallback. The adapter is still a trace source, not a system IME.

Remaining exit work: measure a short paragraph without per-syllable candidate selection.

### M2 — Split touch prototype

Replace buttons with two visual surfaces. Start with a known layout, then add configurable regions and generous hit areas. Record coordinates and contact trajectories, not only recognized symbols.

The known layout has landed as `full-split-1` (all 37 Zhuyin keys plus tone keys, legacy compact positions preserved), with replayable touch/keyboard fixtures under `tests/fixtures/`. Contact trajectories (`touch_move`/`touch_up`) are recorded as raw evidence without affecting decode. Still open: configurable regions. The neutral-tone gesture is answered, not open — tones are optional, see Open questions.

Exit: replaying a touch trace gives the same normalized phonetic events; compare error rate and subjective interruption against M1.

### M3 — Fuzzy spatial decoding *(keyboard-neighborhood prototype started)*

The first fuzzy layer now maps a physical key to weighted neighboring Zhuyin symbols and lets phrase decoding choose among alternatives. Coordinate-aware payloads are preferred over static keyboard neighborhoods. Phrase lookup uses a bounded same-length dictionary scan rather than Cartesian expansion, so unknown long input remains responsive. `tools/noise.py` measures the rescue rate on seeded uniform-disk jittered taps (run: `PYTHONPATH=src python tools/noise.py`). User measurements remain to be added.

Finding (synthetic, 20 seeds × 2 phrases): jitter radius ≤ 0.05 decodes at
100% with no fuzzy help needed; radius 0.08–0.15 is the fuzzy band
(+5 to +55pp over the ablated decoder, e.g. ni-hao at 0.15: 0.55 vs
0.00); radius 0.20 remains degraded (0.30–0.35 fuzzy, 0.00 ablated).
Longer phrases degrade faster, as expected from compounding per-tap error.

Follow-up, coordinate-aware payloads: distance-ranked spatial neighbors in
the touch payload (normalizer prefers them, keyboard neighborhoods remain
the fallback) widened the rescue band — ni-hao at 0.15: 0.50 → 0.70, at
0.20: 0.15 → 0.50; zao-shang-hao at 0.15: 0.25 → 0.45, at 0.20: 0.00 →
0.25. Old traces without spatial payloads replay unchanged.

Follow-up, keyboard-error battery on the real Swift decoder
(`tools/keynoise.py`, stable md5 seeds, 10 seeds/cell; ms column is process
spawn+lexicon load, engine decode stays 0.1–25 ms in-process): short inputs
are robust (ni-hao/wo-shi-xue-sheng: clean/no-tones 1.00, drop/swap/sub
0.50–1.00, harsh 0.30–0.60). The cliff is 9-syllable input under key loss:
dada drop-key 0.70, swap 0.20, harsh 0.00 (recall collapses with top-1, so
rescoring cannot recover). Dada toneless stays top-1 0.00 / recall 1.00 —
pure word-frequency (大對), not structure. Lattice caps are now cost-ranked
and a repair track runs only when the clean merge is not fully clean, so
clean input pays nothing extra. A `yue-lai-yue-phonetic` probe locks the new
phonetic-confusion class (ㄧㄨㄩ taps as u/j/m): recall 1.00 clean and
toneless, 0.80/0.50/0.40/0.20 under drop/swap/sub/harsh noise — top-1 stays
frequency-decided and needs the window or context. Lesson: cross-run
battery comparisons need stable seeds — Python `hash()` is salted per
process and once faked a regression.

Exit: report accuracy, correction rate, latency, and the point at which fuzziness stops helping.

### M4 — Local model and optional LLM

Add a local sentence decoder behind the same interface. An explicitly enabled LLM adapter may rerank or repair a completed trace, but must time out to the offline result and never block capture.

The adapter seam has landed without weights: `DecodeContext` (revision + deadline + cancellation), `DecoderProtocol`, and `decode_with_fallback` (offline-first, bounded to one cancellable adapter slot, rejects slow/failed/stale results). A `StubModelAdapter` proves a 5 s model behind a 10 ms deadline still returns the offline text in well under a second. Remaining: model choice, latency budgets, and provenance surfacing.

Findings and measurements: [lab notebook](lab-notebook.md), “M4 — findings”.

Exit: offline mode is useful on its own; model provenance and timing are visible in measurements.

### M5 — macOS Input Method adapter *(prototype slice landed)*

Package the stable core behind a thin macOS InputMethodKit adapter. `IMKServer` and `IMKInputController` own system integration; they forward key events into the core and send committed text back to the client app. Keep marked text, commit/cancel, language switching, and preferences in the adapter. Do not put fuzzy decoding or model calls in AppKit code.

The first native InputMethodKit bundle is installable through `script/install_ime.sh`. It uses a pinned offline dictionary, whole-composition segmentation, conservative fuzzy rescue, marked text, Return/Space commit, Backspace, Escape, and Latin passthrough. It is a real system-wide experiment, but not yet a production IME: richer punctuation, robust candidate UI, signing/notarization, and shared Python/Rust decoder integration remain open.

Findings and measurements: [lab notebook](lab-notebook.md), “M5 — learning and candidate window”.

## Current state and next steps

Where the project stands, what is open and in which order: [`status.md`](status.md).

## Measures

Track phrase-level character error rate, syllable error rate, commit latency, p50/p95 decode latency, backspaces or replays, candidate interruptions, and task completion time. Log confidence and decoder source for every result. Run a fixed synthetic fixture set plus consented user sessions kept outside the repository.

The main comparison is not raw key accuracy. It is whether users can capture thoughts with fewer interruptions at an acceptable final reconstruction quality.

Long-term positioning: use [vChewing](https://github.com/vChewing/vChewing-macOS)
as the recommended mature Zhuyin baseline. Misstype does not aim to reproduce
vChewing's full feature surface; rather, vChewing provides a daily-usable
stability and candidate flow reference. Misstype's focused differentiators
are learned mixed Chinese/English typing and paired fuzzy correction: combine
keyboard edit evidence with touch-coordinate hypotheses, preserve the raw
trace, and measure adoption, false switches, repair rate, false repairs,
latency, and candidate interruptions against fixed replayable fixtures.

## Open questions

Competitor comparison and feature ideas: [`competitors.md`](competitors.md).

- Does tone input improve segmentation enough to justify a dedicated gesture?
  Finding (fixture-backed, 9-phrase table): no. Tones are optional hints —
  exact-tone matches decode at confidence 1.0, unique toneless matches at
  0.6, ambiguous toneless input stays a visible bracket fallback. No
  dedicated neutral-tone gesture while ambiguity stays near zero; revisit
  with a larger table or user data.
- Which split layouts match existing Zhuyin muscle memory across hand sizes?
- Should a pause commit automatically, or only preview a reconstruction?
- How should Latin text, numbers, punctuation, and code tokens interrupt a Zhuyin span?
- What local model size meets the latency budget on the target device?

