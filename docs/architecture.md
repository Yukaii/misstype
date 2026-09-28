# Technical architecture

## Principles

The system is a pipeline with a stable event log at its center. Capture must remain responsive even when decoding is slow. Every later representation is derived from the raw trace and can be replayed.

Source of truth (decision 2026-09-27): the Swift `MistypeCore` package is the single source of truth for keyboard parsing, decoding, selection, and learning. The Python package (`src/mistype`) is the M0–M2 capture/touch prototype and is slated for replacement; it already diverges (e.g. it treats Space as a separator/neutral tone, while the IME treats it as a strong first tone) and decoder changes are not ported to it. Tools that measure decoding drive the Swift binary (`--decode`, `--replay`), never the Python decoder.

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

`DecodeResult` contains text, token alignment, confidence, decoder name/version, latency, and optional alternatives. The offline decoder is always available. Local models and remote LLMs are adapters behind `DecoderProtocol`, invoked via `decode_with_fallback`: the offline result is computed first, and an adapter result is accepted only when on time, healthy, and stamped for the current revision. `DecodeContext` carries the revision, deadline in milliseconds, and cooperative cancellation event. `AdapterRunner` admits one adapter request at a time; a timeout signals cancellation and later requests fall back while an uncooperative worker unwinds. `StubModelAdapter` locks the timeout/staleness behavior until a real model is chosen. An optional `UserLexicon` overlay adds a deterministic bonus to produced candidates for explicitly learned (readings → text) pairs; nil (the default) means byte-identical decode. `LexiconDecoder.contextBigrams` (`ContextBigrams`, previous word → current word bonus, run-local like learned context rules) is the same kind of re-rank-only overlay for corpus bigrams; nil by default and only set by the dev `MISTYPE_BIGRAM` hook (measurement, see the ChiaKey finding in the project outline).

### Session coordinator

Owns pause detection, explicit commit, revision, and cancellation. Capture events are accepted while a decode is running. A stale result must never overwrite a newer session revision.

The coordinator exposes `ingest`, `preview`, `maybe_commit`, and `commit`, plus `preview_with_adapter` for a deadline-bounded model preview. It snapshots the request revision and rechecks it before returning, so input received while a model runs always wins. It uses event monotonic timestamps and a configurable pause threshold.

### Presentation adapters

The prototype UI shows the live trace, optional preview, committed text, and decoder status. A future IME adapter can consume committed text without changing the core pipeline.

### Platform boundary: InputSession

Every editing rule of the IME lives in `MistypeCore`, so each platform adapter is only I/O (decision 2026-09-28, ahead of a Linux fcitx5/IBus frontend; before this the rules lived in the IMK controller keyed on macOS key codes):

```text
native key event --adapter--> KeyEvent --> InputSession.handle --> KeyResult  (one-shot: commit text, pass through, beep, mode flip)
                                              |
                                              +--> InputSession.view: SessionView  (preedit, UTF-16 caret, candidates, selection, panel visibility)
```

- `KeyEvent` names physical keys by their US-ANSI unshifted label (`.character("a")`, `.space`, `.shift(.left)`, …) because the 大千 layout is positional; adapters map scancodes, never layout characters. `.release` covers key-up and modifier-only transitions (macOS `flagsChanged`), which only feed lone-Shift tap tracking. `modifiers` is the state after the event. Key tables are data in the core (`MacKeyCode`), unit-tested on every platform.
- `KeyResult.consumed == false` means the host passes the key to the application after inserting `commit`. Hosts render `view` after every call and skip unchanged state; inserting a commit clears the client's marked text, so hosts record an empty preedit instead of re-sending it.
- `InputEngine` is the per-process state (decoder, `UserLexicon` + persistence URL, 中/英 mode, `ShiftTapTracker`, recent commits, Jev grading). `SessionSettings` is read through the engine's provider once per event, so preference changes apply on the next keystroke. One `InputSession` per client (IMK controller, fcitx5 input context).
- `InputSessionHost` is the only callback surface: `surroundingContext()` (called only when a Jev request will be attempted, never while decoding offline), `perform(_:)` (hop to the session's thread), `sessionDidChange(_:)` (re-render after an asynchronous Jev pick).
- `LexiconLoader.load(resourceDirectory:)` builds the shipping decoder (lexicon + local phrases + toneless order, word penalty 0.5, dev env hooks) from any directory; `UserLexicon.defaultURL` is `~/Library/Application Support/Mistype` on macOS and `$XDG_DATA_HOME/mistype` (default `~/.local/share`) elsewhere.
- `Package.swift` declares the IMK adapter and the Carbon source tool only on macOS; `swift test` runs the full core suite on Linux too (CI `core-linux`). `InputSessionTests` replay key traces through the session and are the reference for any new adapter.

### macOS adapter (M5)

The macOS system integration is an InputMethodKit target. `IMKServer` manages client connections and each `IMKInputController` owns one `InputSession` (see Platform boundary); the behavior below is the session's, the controller only translates NSEvents and draws `SessionView`. The current native slice keeps a Swift `MistypeCore` boundary for keyboard parsing, composition state, trie-based phrase segmentation, and conservative one-key fuzzy rescue; it sends marked preview text and only committed text back to the client. Space is a boundary, never a commit: after pending keys it marks first tone — strong evidence like any tone key (other tones pay 4.0; RIME bopomofo parity, user decision 2026-09-27) — otherwise it stays a literal separator (empty composition passes it straight through); only Return commits — exactly the preview, raw Bopomofo tail included (注音文; a run that cannot start a syllable, like ㄏㄏㄏㄏ, stays raw whole), trailing whitespace trimmed; Shift+Return commits the keys as typed (`rawPhonetic`, never learned) for 注音文 made of valid syllables, like a lone ㄗ. Accepted text settles: earlier runs and words 3+ syllables before the end become character-level automatic pins (never learned, overridden by explicit picks), so the list only varies text near the cursor. Continuous toneless pending keys convert live as they are typed (`livePendingCut`: the whole run when it segments cleanly, else up to 3 trailing keys — the syllable in progress — stay raw), so tones stay optional and nothing waits for space; decode of a 57-key (26-syllable) toneless run measured ~90 ms per keystroke. They are jointly segmented in `decodeComposition`, fused tone-terminated runs are repaired onto the trailing piece, explicit tones are soft hints (same-base variants stay viable with a penalty, late tones re-hit via `retoneLast`), invalid readings get tiered edit repair (transpose 4.0, neighbor- and
phonetic-confusion substitute 5.0 — ㄧㄨㄩ / 捲平舌 / n-l / nasals ride
along even on valid bases, cost-capped so exact input keeps winning;
insert/delete 6.0 stay gated on no-clean-reading), and destructive editing
(plain Backspace erases one converted syllable when nothing is pending,
else one raw key; Option+Backspace one syllable; Cmd+Backspace clears)
never commits first. An explicitly picked candidate pins by text (Tab/arrows/
digit/click set `pinnedPick`): continued typing keeps the exact match, else
the first candidate extending it; only unmatched fresh evidence clears the
pin. A syllable cursor replaces the old Opt+Right segment lock (retired:
file-trace showed toneless input only beeped, fully toned input committed
exactly like Return). Plain Left/Right move the cursor over the converted
span — the caret parks at the focused word via marked-text selection and the
panel shows that span's options (`segmentOptions`, beam-independent trie
query); Tab/digit/click/Return pin the choice into session-only `locked`
pins (reading-keyed decisive bonus, held till commit/clear/Escape, never
disk) and advance the cursor, Up/Down only move the highlight. Any
composition edit returns the cursor to end; pins survive tail typing.
`SentenceCandidate.alignment` (syllable ↔ UTF-16 char ranges, rebased across
runs in `decodeSegments`) is the single source for caret placement and span
lookup; the cursor indexes the candidate's own decoded `syllables` (a toneless run is one fused syllable in the composition, so a rebuilt list never matched). Surrounding-text lookup (`stringFromRange:` on the client) runs only when a Jev request will genuinely be attempted, never on the hot decode path: eager per-keystroke lookup segfaulted inside Chromium/Electron legacy client wrappers, and offline decoding never needs it. Lexicon data: `script/prepare_lexicon.py` builds `lexicon.tsv` from pinned McBopomofo sources, then applies `Resources/reading_order.tsv` (hand-reviewed single-syllable top-1 swaps; stale rows fail the build); it also writes `toneless.tsv`, where single chars that share a toneless base swap score slots by NAER standalone frequency. `LexiconDecoder(tsv:toneless:)` reads those scores only for a one-syllable span typed without a tone, so toned input and words never see them; `LexiconDecoder.wordPenalty` (0.5 via `LexiconLoader`, 0 in a bare `LexiconDecoder`) charges each dictionary word on a path, rebalancing word vs split-into-chars against McBopomofo's inflated single-char scores; `Resources/local_phrases.tsv` is concatenated at load. The IME binary is launched and supervised by TIS on demand — installers and scripts must never start it by hand, or the stray copy squats the `InputMethodConnectionName` Mach service and the TIS-launched instance fails to bind. Panel echoes are muted 150 ms around our own data-set/drive, and
refresh skips identical panel updates (`displayedTexts`) — the file trace
showed every keystroke's setCandidateData auto-firing Changed(first), which
used to drag selection back to 0; mid-composition Shift brush is ignored for
phonetic keys instead of committing, so fast typing never accepts early. A custom borderless `CandidatesPanel` (own NSPanel, vertical 1–8 list) mirrors the top-8: single source of truth for the highlight, so no IMK sync loop is possible. Its header renders the preedit with our own cursor marker (vChewing floating-buffer idea — some clients never draw the marked-text caret), so the syllable cursor stays visible even where the app draws nothing. Tab/Up/Down step and enter selection mode, where the selection keys (`MistypePrefs.candidateKeys`, default home row `asdfghjk`; Zhuyin keys outside the mode, dim labels) and click pick; any other typing leaves the mode, the first Escape leaves it keeping the text, Return commits; Shift+digit is the full-width symbol layer (＠＃＄％︿＆＊（）＋｛｝～), not selection; plain Left/Right walk the syllable cursor back over the converted span — it indexes the top candidate's own decoded `syllables` (never a list rebuilt from the composition, where a toneless run is one fused syllable), the panel lists every word covering the cursor within its Zhuyin run (`cursorOptions`, longest first), and a pick pins only its span while earlier picks keep their characters outside it (`UserLexicon.pin(_:over:)`; session-only, any edit returns to end), modified arrows commit first and pass through; caret via `IMKTextInput.attributes(forCharacterIndex:lineHeightRectangle:)` walking back from marked end (McBopomofo-style, no permission needed — an Accessibility detour was tried and reverted the same day), falling back to last anchor then mouse. Preferences (`MistypePrefs`: fuzzyRepair, toneTolerance, candidateKeys, userLearning, jevEnabled, jevRichContext, jevApiKey, jevModel) are read live per keystroke from UserDefaults as a `SessionSettings` snapshot and threaded through every decode entry point; the input menu opens the panel. `IMKCandidates` proved undrivable (selectCandidateWithIdentifier: returns YES and moves nothing; synthesized stepping events only beep) and was removed. Punctuation literals and separator spaces pin the current pick and continue (no commit — Return owns that; tone-marking space with pending keys is unaffected). Latin runs work the same way via backtick-toggle (`L:`-marked keys, verbatim, tone/space/punct-terminated), plus Shift-hold letters appending inline with no commit. Candidate UI, preferences, and language switching belong at this boundary. 中/英 mode is a global `InputEngine.english` flag (one keyboard, all clients; Chinese on launch): Shift-tap and Shift+Space toggle, English passes keys straight through like a Latin IME, and a pill flashes plus the input menu shows the mode. Event inlet is raw `handleEvent` (vChewing parity, NOT `inputText`): the server takes the managed path whenever `inputText:key:modifiers:client:` exists and `handleEvent` never fires (verified 2026-09-18), so the controller omits it and parses NSEvents once — tap detection tracks Shift modifier state transitions with hold/cooldown guards, never event types (Electron duplicates cycles). The Swift `MistypeCore` is the single source of truth for decoding behavior (see Principles).

The IME bundle also owns its Text Input Services presentation metadata. The
bundle and the visible `Mistype.Zhuyin` input mode are localized through
`Resources/*/InfoPlist.strings`; the input mode ID must be mapped explicitly or
macOS falls back to showing the internal reverse-DNS identifier in the
Command-Space menu. `tsInputMethodIconFileKey` and
`tsInputModeMenuIconFileKey` point at the bundled 16×16
`MistypeMenuIcon.tiff` (22×16, 16 px high); the larger `MistypeIcon.png` remains the app master so
Text Input Services never uses a 1024×1024 asset as a menu row. The smooth
app master lives in `MistypeIcon.svg`/`MistypeIcon.png`; the menu version has
its own pixel-grid source in `MistypeMenuIcon.svg` and is exported as a hard
edged 16×16 TIFF.

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
5. If explicitly enabled (Preferences: Jev assistance on AND a gateway key present — `JevConfig.canAttempt`), the completed phonetic span may be sent to a local model or remote LLM adapter with a strict deadline and cooperative cancellation. Default is off: decode stays byte-identical to the offline path, and the gate trace logs presence only (never the key or text). A second toggle (`allowRichContext`) gates the richer alignment/diff/contract metadata. Per tied pick at most this leaves the device: raw keys, readings, candidate texts with offline rank/score, up to 60 chars before the cursor, matching learned picks (learning-gated), and recent in-memory commits — never the key, never passwords by policy (do not use in password fields). The Preferences panel states this payload next to the switch and confirms on enable. Calls wait for a settled run (no growing pending run or raw tail: live conversion re-decodes every keystroke, and asking then would send a request per typing pause), send the candidates' own decoded syllables as evidence, and are throttled by `JevTrigger`: skip lone syllables without document context and skip offline leads past 6.0 (measured tie band 0.0–2.6 vs decided 10.3); matching learned picks (`user_preferences`, learning-gated) and recent in-memory commits (`recent_commits`) ride along for disambiguation.
6. Accept an enhanced result only if it belongs to the current revision; otherwise decode the latest offline snapshot.
7. User phrase learning (default on, opt-out in Preferences; local JSON
   only, never network): committing after an explicit pick
   (Tab/arrows/digit/click — never separator pinning) records
   word-level (readings → text) pairs (`UserLexicon.learnedWords`): cursor
   picks of 2+ syllables still pinned at commit, words a whole-sentence pick
   changed versus top-1, or the input itself when it is one word. Whole
   sentences are never stored — the decoder boosts only dictionary words, so
   they never applied. Single characters inside a sentence are learned only
   in context, keyed "previous word|readings" (下次|ㄗㄞ -> 再), and boost
   that char only after that word in the same run — a global 再 bonus would
   bury 在. File format v2; v1 stores load empty (user-approved reset of
   the inert whole-sentence entries). Pairs go into a local capped JSON store
   (`~/Library/Application Support/Mistype/user_phrases.json`, portable —
   copy it to export, Reveal/Clear in Preferences). The next decode of the
   same readings boosts the learned text (+6 first pick, +1 per repeat,
   cap +10). Learning never creates new segmentations, only re-ranks
   produced candidates.
8. Syllable cursor (no modifiers): going back pins a word choice as a
   session-only decisive bonus (+1000, same overlay mechanism as learning
   but never persisted); the sentence still commits once at Return.

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
