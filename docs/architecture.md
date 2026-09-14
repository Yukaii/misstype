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

The M2 touch mapper accepts normalized surface coordinates and returns a nearest physical key plus weighted neighbors. It is deliberately independent of rendering and emits the same `BPMF_FUZZY:<key>` representation used by keyboard fuzzy input.

### Trace store and replay

Append-only session traces are the source of truth. A replay runner feeds the exact same events through later layers for regression tests and latency measurements. Storage should support redaction and an in-memory mode.

### Phonetic normalizer

Converts raw keys or spatial hypotheses into language-neutral `PhoneticToken`s. For Zhuyin, preserve the symbol, tone (if present), boundary evidence, confidence, and alternative symbols. Latin runs and punctuation are separate token kinds.

### Decoder interface

All decoders implement the same asynchronous contract:

```text
decode(PhoneticSpan, DecodeContext) -> DecodeResult
```

`DecodeResult` contains text, token alignment, confidence, decoder name/version, latency, and optional alternatives. The offline decoder is always available. Local models and remote LLMs are adapters with deadlines and cancellation.

### Session coordinator

Owns pause detection, explicit commit, revision, and cancellation. Capture events are accepted while a decode is running. A stale result must never overwrite a newer session revision.

The M1 coordinator currently exposes `ingest`, `preview`, `maybe_commit`, and `commit`. It uses event monotonic timestamps and a configurable pause threshold; model-backed asynchronous cancellation remains future work.

### Presentation adapters

The prototype UI shows the live trace, optional preview, committed text, and decoder status. A future IME adapter can consume committed text without changing the core pipeline.

### macOS adapter (M5)

The macOS system integration is a thin InputMethodKit target. `IMKServer` manages client connections and `IMKInputController` owns per-client input sessions; the adapter translates incoming key events into `RawEvent` and sends only committed text back to the client. Candidate UI, preferences, and language switching belong at this boundary. The core remains platform-independent and testable through replay.

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
4. If explicitly enabled, send the completed phonetic span to a local model or remote LLM adapter with a strict deadline.
5. Accept an enhanced result only if it belongs to the current revision; otherwise retain the offline result.

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
