# Technical architecture

## Principles

The system is a pipeline with a stable event log at its center. Capture must remain responsive even when decoding is slow. Every later representation is derived from the raw trace and can be replayed.

Source of truth (decision 2026-09-27; Linux cutover 2026-10-08; the Swift core was retired on 2026-10-09): the Zig core in `core-zig/` is the single source of truth for keyboard parsing, decoding, selection, and learning, on every platform. Linux (fcitx5) and the macOS IMK adapter use it through the C ABI `misstype.h`; the site demo and video renderer use its wasm32-wasi build. The Python package (`src/misstype`) is the M0–M2 capture/touch prototype and is slated for replacement; it already diverges (e.g. it treats Space as a separator/neutral tone, while the IME treats it as a strong first tone) and decoder changes are not ported to it. Tools that measure decoding drive `misstype-dev` (`--decode`, `--replay`, `--session-trace`), never the Python decoder. Persistent files and configuration stay compatible with what the Swift implementation wrote (frozen fixtures in `tests/capi/golden/`). Pinned utf8proc supplies extended grapheme boundaries and canonical equality; it is statically linked. The Swift reference's outputs are frozen as golden files in `tests/golden/`. See `docs/zig-port.md` for the port, the retirement and the behavior-suite mapping.

**Naming.** This document keeps the Swift-era vocabulary (`InputSession`, `InputEngine`, `SessionView`, `LexiconDecoder`, `UserLexicon`, ...). In the Zig core these are `Session`, `Engine`, `View`, `Lexicon`, `UserLexicon` in `core-zig/src/{session,lexicon,user_lexicon}.zig`; file names such as `MixedDecode.swift` map to `english.zig`, `Touch.swift` to `touch.zig`, `CursorSelection.swift`/`LivePreview.swift`/`CompositionLayout.swift` to parts of `session.zig`/`layout.zig`. Behavior descriptions below still apply.

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

The M2 touch mapper accepts normalized surface coordinates and returns a nearest physical key plus weighted neighbors. It is deliberately independent of rendering and emits the same `BPMF_FUZZY:<key>` representation used by keyboard fuzzy input. The neighbor ranking in the event payload is coordinate-aware (distance-weighted spatial neighbors, top 5); the normalizer prefers it over static keyboard neighborhoods and falls back to them for the keyboard path and older traces. The current layout is versioned (`LAYOUT_VERSION = "full-split-1"`: 20 left-hand keys plus tones 3/4, 21 right-hand keys plus tones 6/7); every event payload keeps the raw `(x, y)` evidence alongside the hypothesis. Tone-key touches emit exact `BPMF:<key>` codes so the normalizer can attach the tone. Tones stay optional: omitting them only lowers confidence on unique matches, so no dedicated neutral-tone touch gesture is planned (see the answered tone question in the project outline). The Swift port is `Sources/MisstypeCore/Touch.swift`: `TouchLayout`/`TouchMapper` (same table and weights, parity locked by golden values in `TouchTests`) and `LexiconDecoder.decodeTouch`: tone taps close runs of Zhuyin taps, each run is segmented into slices of up to 4 taps, and each slice offers the readings of its cheapest 24 key combinations (cost `spatialScale x sum(d - d_nearest)`, default 10, one correction when any tap left its nearest key) so spatial evidence competes with the language score inside the decoder's own beam (`decode(_:options:)`). A second pass adds keyboard edit repair on the 4 cheapest combinations when the first leaves repairs or unresolved text. `decodeTouchBeam` (16 whole-phrase key sequences) is kept as the measured baseline. Not yet wired to `InputSession`; results are in the project outline ("Touch fuzzy port").

### Trace store and replay

Append-only session traces are the source of truth. A replay runner feeds the exact same events through later layers for regression tests and latency measurements. Storage should support redaction and an in-memory mode.

### Phonetic normalizer

Converts raw keys or spatial hypotheses into language-neutral `PhoneticToken`s. For Zhuyin, preserve the symbol, tone (if present), boundary evidence, confidence, and alternative symbols. Latin runs and punctuation are separate token kinds.

### Decoder interface

All decoders implement the same asynchronous contract:

```text
decode(PhoneticSpan, DecodeContext) -> DecodeResult
```

`DecodeResult` contains text, token alignment, confidence, decoder name/version, latency, and optional alternatives. The offline decoder is always available. Local models and remote LLMs are adapters behind `DecoderProtocol`, invoked via `decode_with_fallback`: the offline result is computed first, and an adapter result is accepted only when on time, healthy, and stamped for the current revision. `DecodeContext` carries the revision, deadline in milliseconds, and cooperative cancellation event. `AdapterRunner` admits one adapter request at a time; a timeout signals cancellation and later requests fall back while an uncooperative worker unwinds. `StubModelAdapter` locks the timeout/staleness behavior until a real model is chosen. An optional `UserLexicon` overlay adds a deterministic bonus to produced candidates for explicitly learned (readings → text) pairs; nil (the default) means byte-identical decode. `LexiconDecoder.channel` (`ChannelModel`, typed key → intended key → repair cost) is the per-user half of the noisy channel: a learned pair replaces the generic repair cost for that pair only, clamped at `ChannelModel.floor` so exact input keeps a margin; nil by default (byte-identical decode). `InputSession` sets it per refresh from `InputEngine.channelLearner` when `SessionSettings.channelLearning` and `userLearning` are both on (core default off), and feeds the learner at learning-grade commits: repairs the committed text used, one-key Backspace re-types, and reverts of a repair by an explicit pick (see Personal channel model in the project outline). `LexiconDecoder.repairCostOffset` and `repairValidReadings` are the generic half, picked by the user (issue #21): `SessionSettings.repairStrength` (`RepairStrength`; macOS `MisstypeRepairStrength`, a Settings picker that replaced the fuzzy-repair switch; C ABI `misstype_engine_set_repair_strength`). The offset shifts every generic edit-repair tier (transpose, substitute, phonetic, insert/delete) by that many log units, i.e. scales the assumed slip rate by e^−offset; `repairValidReadings` also runs neighbor/transpose/delete repair on syllables that already spell a real reading (insertion stays gated); such options are word-only (`ReadingOption.wordOnly`): they may complete a multi-syllable word but never stand as a single char, since there only frequency argues for them (好喔→好一). Levels: off (`fuzzy: false`), light (+2, gated), standard (0, gated; byte-identical to before), strong (0, ungated). Both are set per refresh beside `channel`. Tone tolerance and learned channel pairs are unaffected, and light still rescues syllables with no reading (`s3`→你). Measured in `RepairStrengthSweepTests` (project outline, Repair strength): the offset alone moves top-1 by about 2 pp; the gate is the lever. `LexiconDecoder.contextBigrams` (`ContextBigrams`, previous word → current word bonus, run-local like learned context rules) is the same kind of re-rank-only overlay for corpus bigrams; nil by default and only set by the dev `MISSTYPE_BIGRAM` hook (measurement, see the ChiaKey finding in the project outline).

### Session coordinator

Owns pause detection, explicit commit, revision, and cancellation. Capture events are accepted while a decode is running. A stale result must never overwrite a newer session revision.

The coordinator exposes `ingest`, `preview`, `maybe_commit`, and `commit`, plus `preview_with_adapter` for a deadline-bounded model preview. It snapshots the request revision and rechecks it before returning, so input received while a model runs always wins. It uses event monotonic timestamps and a configurable pause threshold.

### Presentation adapters

The prototype UI shows the live trace, optional preview, committed text, and decoder status. A future IME adapter can consume committed text without changing the core pipeline.

The `packages/misstype-wasm` ESM binding exposes the existing WASM key/state
contract to browser integrations. Each loaded module owns one engine/session;
the host supplies WASM and lexicon asset URLs, draws candidates and preedit,
passes through unconsumed keys, and drains committed text with
`takeCommitted()`. The package adds no decoding rules or persistent storage.

### Platform boundary: InputSession

Every editing rule of the IME lives in the Zig core (`core-zig/src/session.zig`), so each platform adapter is only I/O (decision 2026-09-28, ahead of a Linux fcitx5/IBus frontend; before this the rules lived in the IMK controller keyed on macOS key codes):

```text
native key event --adapter--> KeyEvent --> InputSession.handle --> KeyResult  (one-shot: commit text, pass through, beep, mode flip)
                                              |
                                              +--> InputSession.view: SessionView  (preedit, UTF-16 caret, candidates, selection, panel visibility)
```

- `KeyEvent` names physical keys by their US-ANSI unshifted label (`.character("a")`, `.space`, `.shift(.left)`, …) because the 大千 layout is positional; adapters map scancodes, never layout characters. `.release` covers key-up and modifier-only transitions (macOS `flagsChanged`), which only feed lone-Shift tap tracking. `modifiers` is the state after the event. Key tables are data in the core (`MacKeyCode`), unit-tested on every platform.
- `KeyResult.consumed == false` means the host passes the key to the application after inserting `commit`. Hosts render `view` after every call and skip unchanged state; inserting a commit clears the client's marked text, so hosts record an empty preedit instead of re-sending it.
- `InputEngine` is the per-process state (decoder, `UserLexicon` + persistence URL, 中/英 mode, `ShiftTapTracker`). `SessionSettings` is read through the engine's provider once per event, so preference changes apply on the next keystroke. One `InputSession` per client (IMK controller, fcitx5 input context).
- The core has no callback surface: state changes only inside `handle`, `pick` and `commit`. (`InputSessionHost` existed for Jev and was removed with it, 2026-10-09.)
- `LexiconLoader.load(resourceDirectory:)` builds the shipping decoder (lexicon + local phrases + toneless order, word penalty 0.5, dev env hooks) from any directory; `UserLexicon.defaultURL` is `~/Library/Application Support/Misstype` on macOS and `$XDG_DATA_HOME/misstype` (default `~/.local/share`) elsewhere.
- The adapter contract (key translation, applying results, rendering, lifecycle, delivery rules) and the conformance scenarios every platform must pass are in `docs/cross-platform.md`; the Linux (fcitx5) task plan and the C ABI (`misstype.h`) are in `docs/linux-port.md`.
- `Package.swift` declares the macOS targets only (IMK adapter, Settings/installer, Carbon source tool, `MisstypeMacKit` UI types, the Swift bridge to the C ABI). The core is tested by `zig build test` in `core-zig` (CI `zig-core`); `core-zig/src/tests/session_test.zig` (the port of `InputSessionTests`) replays key traces through the session and is the reference for any new adapter.

### macOS adapter (M5)

The macOS system integration is an InputMethodKit target. `IMKServer` manages client connections and each `IMKInputController` owns one `InputSession` (see Platform boundary); the behavior below is the session's, the controller only translates NSEvents and draws `SessionView`. The macOS adapter runs the Zig core (through the C ABI) for keyboard parsing, composition state, trie-based phrase segmentation, and conservative one-key fuzzy rescue; it sends marked preview text and only committed text back to the client. Space is a boundary, never a commit: after pending keys it marks first tone — strong evidence like any tone key (other tones pay 4.0; RIME bopomofo parity, user decision 2026-09-27) — otherwise it stays a literal separator (empty composition passes it straight through); only Return commits — exactly the preview, raw Bopomofo tail included (注音文; a run that cannot start a syllable, like ㄏㄏㄏㄏ, stays raw whole), trailing whitespace trimmed; Shift+Return commits the keys as typed (`rawPhonetic`, never learned) for 注音文 made of valid syllables, like a lone ㄗ. Accepted text settles: earlier runs and words 3+ syllables before the end become character-level automatic pins (never learned, overridden by explicit picks), so the list only varies text near the cursor. Continuous toneless pending keys convert live as they are typed (`livePendingCut`: the whole run when it segments cleanly, else up to 3 trailing keys — the syllable in progress — stay raw), so tones stay optional and nothing waits for space; decode of a 57-key (26-syllable) toneless run measured ~90 ms per keystroke. They are jointly segmented in `decodeComposition`, fused tone-terminated runs are repaired onto the trailing piece, explicit tones are soft hints (same-base variants stay viable with a penalty, late tones re-hit via `retoneLast`), invalid readings get tiered edit repair (transpose 4.0, neighbor- and
phonetic-confusion substitute 5.0 — ㄧㄨㄩ / 捲平舌 / n-l / nasals ride
along even on valid bases, cost-capped so exact input keeps winning;
insert/delete 6.0 stay gated on no-clean-reading), and destructive editing
(plain Backspace erases one converted syllable when nothing is pending,
else one raw key; Option+Backspace one syllable, or a whole Latin word with
the spaces after it; Cmd+Backspace clears) never commits first. An explicitly picked candidate pins by text (Tab/arrows/
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
Insertion caret (decision 2026-10-07, issues #32/#33): the cursor also sets
`Composition.caret`, a raw-key index, and typing goes there
(McBopomofo-style): the cursor shows its focused list but never arms the
selection keys, so home-row Zhuyin keys type at the caret; Tab/Down/Up arm
them, Esc disarms (cursor stays), a second Esc returns the caret to the end.
Edits run through `Composition.atCaret`, which applies the ordinary
end-of-composition rule to the keys before the caret and re-attaches the
rest, and a mid-composition caret is a toneless syllable boundary in
`segments`/`parsed`, so keys typed there fuse backwards (toneless typing as
usual) but never into the syllable after. `CompositionLayout` maps raw keys
to preview UTF-16 offsets and decoded syllables (a body's keys handed out by
each syllable's key count) and gives the word stops: Option+Left/Right jump
to the previous word start / next word end (decoded words, Latin words,
single marks) and resume the Latin run when the caret lands after Latin
text. Mid-composition Backspace erases the decoded syllable before the
caret (Latin: one letter), Forward Delete the one after; Right past the
last syllable or Esc returns to the end. While the caret is mid-composition
the English pass, settled pins, chunked auto-commit and the re-type channel
heuristic are skipped (they read from the end); returning re-decodes. Known
limits: an English reading of the mixed pass has no layout, so Option+arrows
over it still commit and pass; explicit pins after the caret in the same
run stop matching once an insertion shifts their offset; a lone initial
typed mid-composition can be absorbed by delete repair until its syllable
is complete (at the end it would stay raw as `pending`).
`SentenceCandidate.alignment` (syllable ↔ UTF-16 char ranges, rebased across
runs in `decodeSegments`) is the single source for caret placement and span
lookup; the cursor indexes the candidate's own decoded `syllables` (a toneless run is one fused syllable in the composition, so a rebuilt list never matched). The IME never reads surrounding text (`stringFromRange:` on the client): eager per-keystroke lookup segfaulted inside Chromium/Electron legacy client wrappers, offline decoding never needs it, and its only consumer (Jev) was removed 2026-10-09. Lexicon data: `script/prepare_lexicon.py` builds `lexicon.tsv` from pinned McBopomofo sources, then applies `Resources/reading_order.tsv` (hand-reviewed single-syllable top-1 swaps; stale rows fail the build); it also writes `toneless.tsv`, where single chars that share a toneless base swap score slots by NAER standalone frequency. `LexiconDecoder(tsv:toneless:)` reads those scores only for a one-syllable span typed without a tone, so toned input and words never see them; `LexiconDecoder.wordPenalty` (0.5 via `LexiconLoader`, 0 in a bare `LexiconDecoder`) charges each dictionary word on a path, rebalancing word vs split-into-chars against McBopomofo's inflated single-char scores; `Resources/local_phrases.tsv` is concatenated at load. The IME binary is launched and supervised by TIS on demand — installers and scripts must never start it by hand, or the stray copy squats the `InputMethodConnectionName` Mach service and the TIS-launched instance fails to bind. Panel echoes are muted 150 ms around our own data-set/drive, and
refresh skips identical panel updates (`displayedTexts`) — the file trace
showed every keystroke's setCandidateData auto-firing Changed(first), which
used to drag selection back to 0; mid-composition Shift brush is ignored for
phonetic keys instead of committing, so fast typing never accepts early. A custom borderless `CandidatesPanel` (own NSPanel, vertical list, one page of `SessionView.pageSize` rows) mirrors the visible page: single source of truth for the highlight, so no IMK sync loop is possible. Auto-show (`SessionSettings.autoShowCandidates`, macOS `MisstypeAutoShowCandidates`, default off; core/Linux default on) decides whether the panel opens while composing; off, it appears only once selection starts (Tab/Up/Down, syllable cursor; the symbol menu follows the same rule) and closes when selection ends. Return-confirms (`SessionSettings.returnConfirmsSelection`, macOS `MisstypeReturnConfirmsSelection`, default on; core/Linux default off): while selecting (list, focused word, symbol menu) Return only confirms the pick and leaves selection, the next Return commits; off = Return commits at once. Backspace drops separator-derived pins (`settledPins`, non-explicit `pinnedPick`) so erasing a space re-opens the full candidate list. The panel draws only rows (and the mark hint in its footer): the composition and its caret are the client's marked text (decision 2026-10-02: the earlier header that re-drew the preedit with our own `|` cursor marker was removed; a client that draws no marked-text caret now shows none). Down/Up step and enter selection mode; Tab/Shift+Tab and PageUp/PageDown turn pages (default bindings, decision 2026-10-05: Tab no longer steps one row; on a single page the first one only enters selection mode, then it beeps; Tab on a focused word pages its options instead of pinning, which selection keys and Return still do), where the selection keys (`MisstypePrefs.candidateKeys`, default home row `asdfghjk`; Zhuyin keys outside the mode, dim labels) and click pick; any other typing leaves the mode, the first Escape leaves it keeping the text, Return commits; Shift+digit is the full-width symbol layer (＠＃＄％︿＆＊（）＋｛｝～), not selection; plain Left/Right walk the syllable cursor back over the converted span — it indexes the top candidate's own decoded `syllables` (never a list rebuilt from the composition, where a toneless run is one fused syllable), the panel lists every word covering the cursor within its Zhuyin run (`cursorOptions`, longest first), and a pick pins only its span while earlier picks keep their characters outside it (`UserLexicon.pin(_:over:)`; session-only, any edit returns to end), modified arrows commit first and pass through; caret via `IMKTextInput.attributes(forCharacterIndex:lineHeightRectangle:)` walking back from marked end (McBopomofo-style, no permission needed — an Accessibility detour was tried and reverted the same day), falling back to last anchor then mouse. Preferences (`MisstypePrefs`: repairStrength, toneTolerance, candidateKeys, userLearning) are read live per keystroke from UserDefaults as a `SessionSettings` snapshot and threaded through every decode entry point; the input menu opens the panel. Keyboard and panel options (decision 2026-10-05, issue #12): `SessionSettings.pageSize` (candidates per page, 4–10, default 8; selection keys address the first `pageSize` keys, the session pages by it and reports it in `SessionView.pageSize`), `keyBindings` (`KeyBindings.swift`: per `KeyAction` — 中/英 toggle, Down/Up step, pages (Tab/Shift+Tab and PageUp/PageDown), syllable cursor, phrase mark, commit, raw commit, cancel, latin run — a list of `KeyChord`s or the defaults; `resolve` rewrites a bound chord into the action's canonical key before `type` runs, so the editing rules stay keyed on one key set; a removed default goes to the app, except Shift+Space, which becomes a plain Space; printable keys bind only with Control/Option/Command, editing keys never; explicit bindings win over another action's default; macOS stores the text form in `MisstypeKeyBindings`) (`-`/`=` also page while selecting; a selection key wins over them). `cursorCandidates` narrows the syllable cursor's list (vChewing's "cursor in front of / behind the phrase", checked against its source 2026-10-05): `covering` (default, every word covering the cursor syllable, caret before it), `endingAt` (macOS Zhuyin style: words ending after the cursor syllable, caret after it, so the first Left lists the last word) or `beginningAt` (Microsoft New Phonetic style: words starting at it, caret before it). Core defaults equal the previous fixed behavior. The panel look (`PanelStyle`: light/dark/system, a color scheme (`PanelTheme`: system colors with a neutral gray highlight, or Solarized, Nord, Gruvbox, Catppuccin, each with published light and dark palettes picked by the effective appearance), font size 12–24 with row height scaled, and a grid layout showing up to 4 pages as columns: Up/Down walk the list across columns, Tab turns pages, Left/Right stay the syllable cursor, only the current page's column is labeled with selection keys) is macOS-only presentation and never reaches the core. Settings has Appearance and Shortcuts panes for them. `IMKCandidates` proved undrivable (selectCandidateWithIdentifier: returns YES and moves nothing; synthesized stepping events only beep) and was removed. Punctuation literals and separator spaces pin the current pick and continue (no commit — Return owns that; tone-marking space with pending keys is unaffected). Latin runs work the same way via backtick-toggle (`L:`-marked keys, verbatim: letters and digits stay in the run, space too; punctuation or the toggle ends it), plus Shift-hold letters appending inline with no commit; a lone Shift tap mid-composition toggles the same latin run (no commit, no global flip — the 中/英 flip only happens with an empty composition and no run open). An open run survives Esc, Cmd+Backspace and delete-all (decision 2026-10-06: wiping text is not a vote for Zhuyin; only the toggle or a commit key closes it, and the tap that ends it is not a global flip). When the shown text is stranded Zhuyin (an unresolved syllable, or a raw tail longer than one syllable) the tap first re-reads the trailing Zhuyin keys as the letters typed (`Composition.convertTailToLatin`; tones become digits, Space stays) and leaves the run open, so English typed in the wrong mode needs no retyping and no `mixedEnglish`. Smart quotes (`Punctuation.smartQuote`) and the symbol menu (`SymbolMenu`, groups in `Punctuation.groups`; the typed mark is swapped in place via `Composition.replaceLastLiteral`) live in the session, not the adapters. Chunked auto-commit (`commitSettledHead`, `SessionSettings.autoCommitSyllables`, default 24, `defaults write MisstypeAutoCommitSyllables`, 0 = off): once the shown sentence passes the limit, its head — whole words, all but the last `limit / 2` syllables — is returned as `KeyResult.commit` while the tail keeps composing; it only fires when the head is exactly what the keys said (no repairs or unresolved syllables) and no explicit pick, pin, cursor or open list exists, never trains learning, and consumes the head's raw keys. Backspace on a tone that closes a fused toneless body erases one decoded syllable, not the whole body. Backspace keeps an open latin run (and resumes one when it edits back into a latin tail), so fixing a typo needs no re-toggle. Clients that cannot show marked text (decision 2026-10-06, after vChewing's "mitigation level 2": Electron/WebView apps, detected by an `electron`/`mswebview`/`slimcorewebview` mark in Info.plist or `Frameworks/`, plus a built-in list and `MisstypePopupCompositionClients`) get a floating `CompositionPopup` below the caret with the preedit, caret and phrase mark, while the client receives a one-space placeholder as marked text so IMK keeps the composition alive and leaks no later keys; the blanket Electron rule (`MisstypePopupCompositionForElectron`) is OFF by default because several Electron apps (Obsidian) draw marked text fine; apps that do not are listed by bundle ID: built-ins plus a per-app input-menu toggle "Floating composition in this app" (`MisstypePopupCompositionClients` forces the popup, `MisstypeNativeCompositionClients` forces native and wins). The toggle exists because the broken case is a single element (t3code's terminal) inside an app whose other fields work, and the probe could not tell them apart (caret height 18 in the input vs 21 in the terminal was the only difference). Native-vs-popup cannot be detected at run time: after `setMarkedText` the working Obsidian and the broken t3code report identical `markedRange` / `attributedSubstring` / rect results (probe log, 2026-10-06), because those answer from the client's text model, not from what it paints. Marked text is sent as one clause segment per word (decision 2026-10-06, as vChewing/McBopomofo do): `SessionView.segments` (UTF-16 ranges tiling the preedit, from the shown candidate's alignment, with Latin/punctuation gaps and the raw tail as their own segments) and `focus` (the syllable cursor's word); the IMK adapter gives each segment its own `markedClauseSegment` index with underline style 1, the focused word style 2 (thick), so clients draw a split underline. Candidate UI, preferences, and language switching belong at this boundary. 中/英 mode is a global `InputEngine.english` flag (one keyboard, all clients; Chinese on launch): Shift-tap and Shift+Space toggle, English passes keys straight through like a Latin IME, and a pill flashes plus the input menu shows the mode. Event inlet is raw `handleEvent` (vChewing parity, NOT `inputText`): the server takes the managed path whenever `inputText:key:modifiers:client:` exists and `handleEvent` never fires (verified 2026-09-18), so the controller omits it and parses NSEvents once — tap detection tracks Shift modifier state transitions with hold/cooldown guards, never event types (Electron duplicates cycles). The Swift `MisstypeCore` is the single source of truth for decoding behavior (see Principles).

The IME bundle also owns its Text Input Services presentation metadata. The
bundle and the visible `Misstype.Zhuyin` input mode are localized through
`Resources/*/InfoPlist.strings`; the input mode ID must be mapped explicitly or
macOS falls back to showing the internal reverse-DNS identifier in the
Command-Space menu. `tsInputMethodIconFileKey` and
`tsInputModeMenuIconFileKey` point at the bundled 16×16
`MisstypeMenuIcon.tiff` (22×16, 16 px high); the larger `MisstypeIcon.png` remains the app master so
Text Input Services never uses a 1024×1024 asset as a menu row. The smooth
app master lives in `MisstypeIcon.svg`/`MisstypeIcon.png`; the menu version has
its own pixel-grid source in `MisstypeMenuIcon.svg` and is exported as a hard
edged 16×16 TIFF.

**App Sandbox (macOS, decision 2026-10-04, from vChewing's design).** The IME is signed with `Resources/Misstype.entitlements`: `app-sandbox`, `network.client` (Sparkle update checks and downloads; decoding opens no socket), `files.user-selected.read-only` (Settings → My Dictionary → Import… reads the one file the user picks; the merge goes into the editor and applies only on Save) and the `mach-register.global-name` exception for the IMK connection name (must equal `InputMethodConnectionName`). A sandboxed process cannot obtain a global keyboard tap, which backs the privacy stance. Consequences: `homeDirectoryForCurrentUser` resolves into `~/Library/Containers/org.misstype.inputmethod.Misstype/Data`, so the user files and the debug log live there (the paths in `cross-platform.md` §6 are container-relative); pre-sandbox files in the real home are not migrated (closed beta, never published). Anything outside the container needs a user-granted bookmark (not used yet). Verified on a real Mac (2026-10-04, ad-hoc signed build): IMK connection, typing and marked text, candidate panel, Settings Reveal in Finder, user dictionary save. Not yet verified: Developer ID signed/notarized build from `package_release.sh`.

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
5. Decoding is offline only. Remote assistance (Jev, an opt-in LLM
   re-ranker) was removed on 2026-10-09; LLM re-ranking remains a
   tools-only experiment (`tools/lm_choose.py`), never wired to the IME.
6. Accept an enhanced result only if it belongs to the current revision; otherwise decode the latest offline snapshot.
7. User phrase learning (default on, opt-out in Preferences; local JSON
   only, never network): committing after an explicit pick
   (Tab/arrows/digit/click — never separator pinning) that corrected
   something records word-level (readings → text) pairs
   (`UserLexicon.learnedWords`): cursor picks of 2+ syllables still pinned
   at commit, words a whole-sentence pick changed versus top-1, or the input
   itself when it is one word. A pick that only confirms what was shown (top
   row, or Return on a focused word showing that option) pins for the
   session but never trains words or the channel model (`learnPins`;
   learning confirmations stored the decoder's own mistakes, 2026-10-06). Whole
   sentences are never stored — the decoder boosts only dictionary words, so
   they never applied. Single characters inside a sentence are learned only
   in context, keyed "previous word|readings" (下次|ㄗㄞ -> 再), and boost
   that char only after that word in the same run — a global 再 bonus would
   bury 在. File format v2; v1 stores load empty (user-approved reset of
   the inert whole-sentence entries). Pairs go into a local capped JSON store
   (`~/Library/Application Support/Misstype/user_phrases.json`, portable —
   copy it to export, Reveal/Clear in Preferences). The next decode of the
   same readings boosts the learned text (+6 first pick, +1 per repeat,
   cap +10). Learning never creates new segmentations, only re-ranks
   produced candidates.
9. User dictionary (explicit, local, always on): unlike learning it creates
   paths. Shift+Left/Right mark syllables of the converted text (from the
   cursor, else the end); `SessionView.mark` carries the UTF-16 range, the
   text, the toned reading and what Return will do. Return files the 2–8
   syllable span in `UserDictionary` (`user_dictionary.tsv`, sibling of
   `user_phrases.json`: `text reading [weight]` (vChewing userdata format; the legacy `reading<TAB>text` order is still read, decision 2026-10-04), `!` lines hide a
   built-in word) or, when the pair is already there, removes it; it never
   commits. `InputEngine.setUserDictionary` persists and calls
   `LexiconDecoder.applyUserDictionary`, which writes the words into the trie
   as ordinary entries (default weight 0, above every built-in score) and can
   restore the built-in lexicon exactly; readings come from
   `LexiconDecoder.readings(of:syllables:span:)`, the tone-exact path of the
   displayed word, so toneless typing still files toned readings. A mark may
   not cross punctuation/Latin or raw-Zhuyin text. The file is re-read when a
   composition starts if its mtime changed, so the macOS Settings "My
   Dictionary" pane (a text editor over the same file) and any external edit
   apply without a restart. Linux (fcitx5) gets the same behavior through the
   C ABI: `misstype_engine_set_user_dictionary_path` and the appended
   `misstype_view.mark_*` fields; the addon draws the mark as a highlighted
   preedit segment and the hint in the aux-down line (C13). Only the editor is
   macOS-only for now.
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

### Mixed-language decode

`LexiconDecoder.decodeMixed(keys:english:)` (`MixedDecode.swift`) reads bare keys as English when that wins on score: candidate English spans (exact words of an `EnglishLexicon` or one edit away for words of 5+ letters) are decoded as latin segments through `decodeSegments` and priced `word ln p - 6 x edits - switchPenalty` (default 4) against the all-Chinese reading. The English list is built by `script/prepare_lexicon.py` from the pinned FrequencyWords source into `.cache/frequencywords/english.tsv` and is optional: without it nothing changes. Measurements and limits are in the project outline ("Mixed Chinese/English without a switch").

Session wiring: after `livePreview`, `InputSession.refresh` calls `applyEnglish` when `SessionSettings.mixedEnglish` is on and `InputEngine.englishLexicon` (loaded off-thread from `english.tsv`) exists. The English reading is inserted first when it beats the Chinese one by `MixedDecoding.autoMargin` beyond the penalty, second within `suggestWindow`, else not at all. Inserted readings are tracked in `completeTexts`: preedit shows no raw tail with them, and they are excluded from settled pins, `pinDifferences`, the syllable cursor (`focusFrame`), chunked auto-commit and learning, since their positional run indexes differ from the composition's. Punctuation, earlier latin keys and spaces in the composition are carried through unchanged; English spans are bare letter keys, optionally led by Shift-typed latin capitals (`Python`). Live readings show the syllable being typed as raw Zhuyin and charge `rawKeyCost` per raw key; a different extra letter after a whole word is never read as a typo. macOS default off (`MisstypeMixedEnglish`), core and C ABI default on when the word list is present; the C struct is unchanged.
