# Project outline

## Problem

Conventional touch keyboards make the user divide attention between composing and locating small, exact targets. Chinese input adds another interruption: choosing candidates while the thought is still forming. Mistype explores whether a forgiving split surface can preserve a user's learned hand motion and postpone linguistic decisions until a phrase is complete.

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
- Cloud inference, accounts, sync, and social features.
- Automatic learning from personal text without an explicit opt-in and export path.

## Milestones

### M0 — Decoder seam

Feed a complete delayed phonetic stream into a decoder and emit one sentence. Use hand-authored fixtures first. This validates the core UX independently of touch hardware.

Exit: replay is deterministic; Chinese, English, and mixed fixtures produce an inspectable result; raw input remains available.

### M1 — Zhuyin capture *(prototype slice complete)*

The first keyboard adapter now maps standard physical Zhuyin keys into phonetic tokens and attaches tone keys to the preceding symbol. The adapter is still a trace source, not a system IME.

Remaining exit work: add a session coordinator with debounce/commit and measure a short paragraph without per-syllable candidate selection.

### M2 — Split touch prototype

Replace buttons with two visual surfaces. Start with a known layout, then add configurable regions and generous hit areas. Record coordinates and contact trajectories, not only recognized symbols.

The known layout has landed as `full-split-1` (all 37 Zhuyin keys plus tone keys, legacy compact positions preserved), with replayable touch/keyboard fixtures under `tests/fixtures/`. Contact trajectories (`touch_move`/`touch_up`) are recorded as raw evidence without affecting decode. Still open: configurable regions. The neutral-tone gesture is answered, not open — tones are optional, see Open questions.

Exit: replaying a touch trace gives the same normalized phonetic events; compare error rate and subjective interruption against M1.

### M3 — Fuzzy spatial decoding *(keyboard-neighborhood prototype started)*

The first fuzzy layer now maps a physical key to weighted neighboring Zhuyin symbols and lets phrase decoding choose among alternatives. Coordinate-based uncertainty and user measurements remain to be added.

Exit: report accuracy, correction rate, latency, and the point at which fuzziness stops helping.

### M4 — Local model and optional LLM

Add a local sentence decoder behind the same interface. An explicitly enabled LLM adapter may rerank or repair a completed trace, but must time out to the offline result and never block capture.

Exit: offline mode is useful on its own; model provenance and timing are visible in measurements.

### M5 — macOS Input Method adapter

Package the stable core behind a thin macOS InputMethodKit adapter. `IMKServer` and `IMKInputController` own system integration; they forward key events into the core and send committed text back to the client app. Keep marked text, commit/cancel, language switching, and preferences in the adapter. Do not put fuzzy decoding or model calls in AppKit code.

The macOS adapter is deliberately deferred until M2–M4 establish interaction quality and latency. A simulator can run on macOS earlier, but system-wide IME installation is a separate milestone.

## Measures

Track phrase-level character error rate, syllable error rate, commit latency, p50/p95 decode latency, backspaces or replays, candidate interruptions, and task completion time. Log confidence and decoder source for every result. Run a fixed synthetic fixture set plus consented user sessions kept outside the repository.

The main comparison is not raw key accuracy. It is whether users can capture thoughts with fewer interruptions at an acceptable final reconstruction quality.

## Open questions

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
