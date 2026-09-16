# Technical architecture

## Principles

The system is a pipeline with a stable event log at its center. Capture must remain responsive even when decoding is slow. Every later representation is derived from the raw trace and can be replayed.

```text
input surface / keyboard
        ↓
raw event log
        ↓
phonetic normalization + uncertainty
        ↓
phrase decoder (offline first)
        ↓
optional local model / LLM reranker
        ↓
preview and committed text adapters
```

## Components

### Capture layer

Platform-specific adapters emit `RawEvent` values for both surfaces. The first implementation may be a desktop or mobile simulator. It must not know Chinese rules or call a model.

The M2 touch mapper accepts normalized surface coordinates and returns a nearest physical key plus weighted neighbors. It is deliberately independent of rendering and emits the same `BPMF_FUZZY:<key>` representation used by keyboard fuzzy input. The neighbor ranking in the event payload is coordinate-aware (distance-weighted spatial neighbors, top 5); the normalizer prefers it over static keyboard neighborhoods and falls back to them for the keyboard path and older traces. The current layout is versioned (`LAYOUT_VERSION = "full-split-1"`: 20 left-hand keys plus tones 3/4, 21 right-hand keys plus tones 6/7); every event payload keeps the raw `(x, y)` evidence alongside the hypothesis. Tone-key touches emit exact `BPMF:<key>` codes so the normalizer can attach the tone. Tones stay optional: omitting them only lowers confidence on unique matches, so no dedicated neutral-tone touch gesture is planned (see the answered tone question in the project outline).

### Trace store and replay

Append-only session traces are the source of truth. A replay runner feeds the exact same events through later layers for regression tests and latency measurements. Storage should support redaction and an in-memory mode.

### Phonetic normalizer

Converts raw keys or spatial hypotheses into language-neutral `PhoneticToken`s. For Zhuyin, preserve the symbol, tone (if present), boundary evidence, confidence, and alternative symbols. Latin runs and punctuation are separate token kinds.

### Decoder interface

All decoders implement the same asynchronous contract:

```text
decode(PhoneticSpan, DecodeContext) -> DecodeResult
```

`DecodeResult` contains text, token alignment, confidence, decoder name/version, latency, and optional alternatives. The offline decoder is always available. Local models and remote LLMs are adapters behind `DecoderProtocol`, invoked via `decode_with_fallback`: the offline result is computed first, and an adapter result is accepted only when on time, healthy, and stamped for the current revision. `DecodeContext` carries the revision, deadline in milliseconds, and cooperative cancellation event. `AdapterRunner` admits one adapter request at a time; a timeout signals cancellation and later requests fall back while an uncooperative worker unwinds. `StubModelAdapter` locks the timeout/staleness behavior until a real model is chosen.

### Session coordinator

Owns pause detection, explicit commit, revision, and cancellation. Capture events are accepted while a decode is running. A stale result must never overwrite a newer session revision.

The coordinator exposes `ingest`, `preview`, `maybe_commit`, and `commit`, plus `preview_with_adapter` for a deadline-bounded model preview. It snapshots the request revision and rechecks it before returning, so input received while a model runs always wins. It uses event monotonic timestamps and a configurable pause threshold.

### Presentation adapters

The prototype UI shows the live trace, optional preview, committed text, and decoder status. A future IME adapter can consume committed text without changing the core pipeline.

### macOS adapter (M5)

The macOS system integration is an InputMethodKit target. `IMKServer` manages client connections and `IMKInputController` owns per-client input sessions. The current native slice keeps a Swift `MistypeCore` boundary for keyboard parsing, composition state, trie-based phrase segmentation, and conservative one-key fuzzy rescue; it sends marked preview text and only committed text back to the client. Space is a boundary, never a commit: after pending keys it marks first tone, otherwise it stays a literal separator (empty composition passes it straight through); only Return commits, trailing whitespace trimmed. Continuous toneless pending keys are jointly segmented in `decodeComposition`, fused tone-terminated runs are repaired onto the trailing piece, explicit tones are soft hints (same-base variants stay viable with a penalty, late tones re-hit via `retoneLast`), invalid readings get tiered edit repair (transpose 4.0, neighbor- and
phonetic-confusion substitute 5.0 — ㄧㄨㄩ / 捲平舌 / n-l / nasals ride
along even on valid bases, cost-capped so exact input keeps winning;
insert/delete 6.0 stay gated on no-clean-reading), and destructive editing
(plain Backspace erases one converted syllable when nothing is pending,
else one raw key; Option+Backspace one syllable; Cmd+Backspace clears)
never commits first. An explicitly picked candidate pins by text (Tab/arrows/
digit/click set `pinnedPick`): continued typing keeps the exact match, else
the first candidate extending it; only unmatched fresh evidence clears the
pin. Panel echoes are muted 150 ms around our own data-set/drive, and
refresh skips identical panel updates (`displayedTexts`) — the file trace
showed every keystroke's setCandidateData auto-firing Changed(first), which
used to drag selection back to 0; mid-composition Shift brush is ignored for
phonetic keys instead of committing, so fast typing never accepts early. A custom borderless `CandidatesPanel` (own NSPanel, vertical 1–8 list) mirrors the top-8: single source of truth for the highlight, so no IMK sync loop is possible. Tab/Up/Down step, Shift+digit and click pick, Return commits, Escape hides; caret via `IMKTextInput.attributes(forCharacterIndex:lineHeightRectangle:)` walking back from marked end (McBopomofo-style, no permission needed — an Accessibility detour was tried and reverted the same day), falling back to last anchor then mouse. `IMKCandidates` proved undrivable (selectCandidateWithIdentifier: returns YES and moves nothing; synthesized stepping events only beep) and was removed. Punctuation literals stay inside the composition — `decodeSegments` converts Zhuyin runs and passes punctuation through in place, one commit at the end — matching the Python mixed-span model. Latin runs work the same way via backtick-toggle (`L:`-marked keys, verbatim, tone/space/punct-terminated). Candidate UI, preferences, and language switching belong at this boundary. The Python core remains the replay and experiment reference until the contracts are unified.

## Core data contracts

```text
RawEvent {
  session_id, sequence, timestamp_ns,
  surface: left | right,
  kind: touch_down | touch_move | touch_up | key | gesture,
  x?, y?, pressure?, code?, payload?
}

PhoneticToken {
  span_id, index, kind: zhuyin | latin | punctuation | boundary,
  value, tone?, confidence,
  alternatives: [{ value, confidence }]
}

DecodeResult {
  revision, text, alignment, confidence,
  decoder_id, decoder_version, latency_ms,
  alternatives?
}
```

Use monotonic timestamps for ordering and a separate wall-clock field only for diagnostics. Sequence numbers make dropped or duplicated events detectable.

## Decode policy

1. Normalize and segment without blocking capture.
2. Produce an offline preview after a short debounce.
3. On commit or a longer pause, run phrase-level offline decoding.
4. Tone marks are optional hints: an exact-tone match commits at full
   confidence, a unique toneless match at reduced confidence, and an
   ambiguous toneless match stays a visible fallback for later repair.
5. If explicitly enabled, send the completed phonetic span to a local model or remote LLM adapter with a strict deadline and cooperative cancellation.
6. Accept an enhanced result only if it belongs to the current revision; otherwise decode the latest offline snapshot.

Remote input is opt-in and should be represented in the UI and event metadata. No remote call is required for correctness.

## Suggested repository shape

```text
docs/                 product and architecture decisions
src/capture/          platform adapters and event types
src/phonetic/         Zhuyin, Latin, segmentation, uncertainty
src/decoder/          offline and model-backed implementations
src/session/          revisions, debounce, commit, cancellation
src/ui/               simulator and inspection views
tests/fixtures/       synthetic traces and expected results
tools/                replay, benchmark, and redaction utilities
```

The language and UI toolkit remain open until M0/M1 experiments establish the latency and portability requirements. Keep these boundaries independent of that choice.

## Failure and observability

Capture failures must be visible and recoverable without losing already-recorded events. Decoder failures fall back to the last offline result. Record structured metrics for event drops, queue depth, decode latency, timeout, confidence, and decoder source; never log raw text by default.
