# Technical architecture

## Principles

The system is a pipeline with a stable event log at its center. Capture must remain responsive even when decoding is slow. Every later representation is derived from the raw trace and can be replayed.

Source of truth (decision 2026-09-27; Linux cutover 2026-10-08; the Swift core was retired on 2026-10-09; the Python prototype on 2026-11-11): the Zig core in `core-zig/` is the single implementation of keyboard parsing, decoding, selection and learning, on every platform. Native adapters (macOS IMK, fcitx5, IBus) link its C ABI `misstype.h`; the WebAssembly module is that same ABI compiled for wasm32-wasi (ABI v3), used through `packages/misstype-wasm` by the site, the video renderer and the Obsidian plugin. Tools that measure decoding drive `misstype-dev` (`--decode`, `--replay`, `--session-trace`, `--touch`, `--touch-batch`) through `tools/misstype_dev.py`. Persistent files and configuration stay compatible with what the Swift implementation wrote (frozen fixtures in `tests/capi/golden/`), and the Swift reference's outputs are frozen as golden files in `tests/golden/` ([`zig-port.md`](zig-port.md)). Pinned utf8proc supplies extended grapheme boundaries and canonical equality; it is statically linked.

Names below are the Zig core's (`Session`, `Engine`, `View`, `Lexicon`, `Settings`, … in `core-zig/src/`); names in the macOS adapter section that start with `Misstype` or describe panels and preferences belong to the Swift IMK adapter. Dated experiments behind these decisions are in [`lab-notebook.md`](lab-notebook.md).

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

Touch evidence is the raw `(x, y)` of each tap on a versioned layout (`touch.version = "full-split-1"`: 20 left-hand keys plus tones 3/4, 21 right-hand keys plus tones 6/7). `touch.hypothesis` ranks the five nearest keys of the tapped surface by distance and weight; the raw coordinates are kept beside the hypothesis, never replaced by it. JSONL traces (`tests/fixtures/*.jsonl`) record taps as `touch_down` events with `x`/`y` payloads. Tones stay optional: omitting them only lowers confidence on unique matches, so no dedicated neutral-tone touch gesture is planned (see the answered tone question in the project outline). Decoding lives in `core-zig/src/touch.zig`: `touch.decode` closes runs of Zhuyin taps at tone taps, segments each run into slices of up to 4 taps, and lets each slice offer the readings of its cheapest 24 key combinations (cost `spatial_scale x sum(d - d_nearest)`, default 10, one correction when any tap left its nearest key) so spatial evidence competes with the language score inside the decoder's own beam (`Lexicon.decodeSegments`). A second pass adds keyboard edit repair on the 4 cheapest combinations when the first leaves repairs or unresolved text. `touch.decodeBeam` (16 whole-phrase key sequences) is kept as the measured baseline; `core-zig/src/tests/touch_test.zig` locks both. Not yet wired to `Session`; measure with `misstype-dev --touch` and `tools/noise.py` (lab notebook, "Touch fuzzy port").

### Trace store and replay

Append-only session traces are the source of truth. Replay feeds the same events through the core for regression tests and latency measurements: key strings through `misstype-dev --session-trace` (and `core-zig/bench/replay.sh`), JSONL traces through `tools/replay.py` and `tools/bench.py`. The IMEs keep an opt-in local debug key log for turning a reported bug into a fixture; nothing is stored by default.

### Composition (phonetic parsing)

`Composition` (`composition.zig`) holds the raw keys and parses them into syllables on demand: a tone key closes a syllable, a toneless run stays one fused body that the decoder segments, and Latin runs and punctuation are literals between Zhuyin runs. Parsing never discards keys; the decoder's alignment maps every output character back to the keys that produced it.

### Decoder interface

Decoding is offline, deterministic and synchronous: `Lexicon.decodeSegments` turns a composition's segments into ranked `Candidate`s (text, score, repair and unresolved counts, and `alignment` from syllables to UTF-16 character ranges). It is always available and needs no model, network or key. The asynchronous model-adapter seam of the Python prototype (`DecoderProtocol`, `decode_with_fallback`, a single-slot runner, a stub adapter) was retired with it; remote assistance (Jev) was removed from the IME on 2026-10-09. A future model must keep the same rule: compute the offline result first and accept a model result only when it is on time and belongs to the current input. An optional `UserLexicon` overlay adds a deterministic bonus to produced candidates for explicitly learned (readings → text) pairs; nil (the default) means byte-identical decode. `Lexicon` decode option `channel` (`ChannelModel`, typed key → intended key → repair cost) is the per-user half of the noisy channel: a learned pair replaces the generic repair cost for that pair only, clamped at `ChannelModel.floor` so exact input keeps a margin; nil by default (byte-identical decode). `Session` sets it per refresh from `Engine.channel_learner` when `Settings.channel_learning` and `user_learning` are both on (core default off), and feeds the learner at learning-grade commits: repairs the committed text used, one-key Backspace re-types, and reverts of a repair by an explicit pick (see Personal channel model in the lab notebook). `repair_cost_offset` and `repair_valid_readings` are the generic half, picked by the user (issue #21): `Settings.repair_strength` (`RepairStrength`; macOS `MisstypeRepairStrength`, a Settings picker that replaced the fuzzy-repair switch; C ABI `misstype_engine_set_repair_strength`). The offset shifts every generic edit-repair tier (transpose, substitute, phonetic, insert/delete) by that many log units, i.e. scales the assumed slip rate by e^−offset; `repair_valid_readings` also runs neighbor/transpose/delete repair on syllables that already spell a real reading (insertion stays gated); such options are word-only (`Option.word_only`): they may complete a multi-syllable word but never stand as a single char, since there only frequency argues for them (好喔→好一). Levels: off (`fuzzy: false`), light (+2, gated), standard (0, gated; byte-identical to before), strong (0, ungated). Both are set per refresh beside `channel`. Tone tolerance and learned channel pairs are unaffected, and light still rescues syllables with no reading (`s3`→你). Measured by the Swift `RepairStrengthSweepTests` (lab notebook, Repair strength; the sweep was not ported): the offset alone moves top-1 by about 2 pp; the gate is the lever. The Swift core also had a re-rank-only corpus-bigram overlay set by a dev `MISSTYPE_BIGRAM` hook (the ChiaKey finding in the lab notebook); it was not ported. Corpus context now comes from the optional homophone word-bigram table (`homophone.zig`, `homophone.bin`).

Learned word and context bonuses use toneless keys, but apply only when
every explicitly typed tone in that word agrees with its dictionary reading
(including Space for first tone). Untoned syllables remain unconstrained;
key repairs that preserve a supplied tone can still receive the bonus.
Tone-tolerant alternatives remain candidates at their ordinary repair cost,
and explicit session picks still override the preview. This avoids a stored
暗暗 preference cancelling the first-tone evidence in `0 0sucl`.

A tone key closes a captured run, which can still contain an earlier
untoned syllable. Even when the whole run is a valid reading, the decoder
also tries an apical initial (ㄓㄔㄕㄖㄗㄘㄙ) plus the remaining keys if
an existing two-syllable dictionary word supports that split with no key
or tone repair (`split_valid_tone_runs`). The supplied tone belongs to the
tail; the atomic reading remains viable at its original score. For example,
`-4gj3` can produce 二十五 as well as 二屬. Other valid runs stay atomic;
splitting every vowel combination increased latency and caused a regression
in the typing simulation. This is an offline hypothesis expansion, not a
frequency boost or a change to the captured keys.

Developer ablation only: `Lexicon.repair_requires_no_clean` (default false;
`MISSTYPE_REPAIR_REQUIRES_NO_CLEAN=1` in misstype-dev) gates additional
repair segmentations on whether any complete zero-repair candidate survives
the initial beam, instead of whether its first candidate is clean. It
isolates how language ranking can trigger more search; it does not remove
all score dependence, since the beam is still score-pruned. It is not exposed
in adapter settings or enabled by the C ABI/wasm loaders. The dev typing
experiment found no selection/coverage gain and 20 extra preview changes,
so production keeps its existing gate. Calibration clears this shell flag
to prevent it silently changing the declared parameter profiles.

### Session

`Session` (`session.zig`) owns the composition, picks, pins, the syllable cursor, chunked commit and learning. Every key is handled synchronously and re-decodes the composition (live conversion), so no stale result can overwrite newer input and capture never waits on anything slower than the decoder (per-key latency is measured by `tools/session_latency.py` and `tools/mixed_latency.py`). There is no pause commit: Return commits, and chunked auto-commit (below) keeps long compositions bounded.

### Presentation adapters

The prototype UI shows the live trace, optional preview, committed text, and decoder status. A future IME adapter can consume committed text without changing the core pipeline.

The `packages/misstype-wasm` ESM binding wraps the C ABI compiled for
wasm32-wasi: one engine made from in-memory lexicons
(`misstype_engine_new_from_data`) and one session per `MisstypeWasm`. The host
supplies asset URLs or bytes, feeds DOM key codes (`misstype_key_from_dom_code`),
draws `state()` (the JSON view, `misstype_session_view_json`), passes through
unconsumed keys and drains committed text with `takeCommitted()`; learned
state and the user dictionary go in and out as data. The package adds no
decoding rules or persistent storage.

### Platform boundary: Session

Every editing rule of the IME lives in the Zig core (`core-zig/src/session.zig`), so each platform adapter is only I/O (decision 2026-09-28, ahead of a Linux fcitx5/IBus frontend; before this the rules lived in the IMK controller keyed on macOS key codes):

```text
native key event --adapter--> KeyEvent --> Session.handle --> KeyResult  (one-shot: commit text, pass through, beep, mode flip)
                                              |
                                              +--> Session.view: View  (preedit, UTF-16 caret, candidates, selection, panel visibility)
```

- `KeyEvent` names physical keys by their US-ANSI unshifted label (`kind = .character` with label `"a"`, `.space`, `.shift_left`, …) because the 大千 layout is positional; adapters map scancodes, never layout characters. `release` covers key-up and modifier-only transitions (macOS `flagsChanged`), which only feed lone-Shift tap tracking. `modifiers` is the state after the event. Key tables are data in the core (`misstype_key_from_mac`, `misstype_key_from_evdev`, `misstype_key_from_dom_code` in `capi.zig`), tested on every platform.
- `KeyResult.consumed == false` means the host passes the key to the application after inserting `commit`. Hosts render `view` after every call and skip unchanged state; inserting a commit clears the client's marked text, so hosts record an empty preedit instead of re-sending it.
- `Engine` is the per-process state (decoder, `UserLexicon` and its path, user dictionary, channel learner, 中/英 mode, `ShiftTapTracker`); an engine made from data has no paths and keeps everything in memory. Adapters set `Engine.settings` when preferences change, and it is read once per event, so changes apply on the next keystroke. One `Session` per client (IMK controller, fcitx5/IBus input context, browser page).
- The core has no callback surface: state changes only inside `handle`, `pick` and `commit`. (`InputSessionHost` existed for Jev and was removed with it, 2026-10-09.)
- `misstype_engine_new(resource_dir, …)` (`capi.zig`, `loadDecoder`) builds the shipping decoder (lexicon + local phrases + toneless order + optional homophone table and `english.tsv`, word penalty 0.5) from any directory; `misstype_engine_new_from_data` does the same from bytes. `storage.defaultPath` is `~/Library/Application Support/Misstype` on macOS and `$XDG_DATA_HOME/misstype` (default `~/.local/share`) elsewhere.
- The adapter contract (key translation, applying results, rendering, lifecycle, delivery rules) and the conformance scenarios every platform must pass are in `docs/cross-platform.md`; the Linux (fcitx5) task plan and the C ABI (`misstype.h`) are in `docs/linux-port.md`.
- `Package.swift` declares the macOS targets only (IMK adapter, Settings/installer, Carbon source tool, `MisstypeMacKit` UI types, the Swift bridge to the C ABI). The core is tested by `zig build test` in `core-zig` (CI `zig-core`); `core-zig/src/tests/session_test.zig` (the port of `InputSessionTests`) replays key traces through the session and is the reference for any new adapter.

### macOS adapter (M5)

The macOS system integration is an InputMethodKit target. `IMKServer` manages client connections and each `IMKInputController` owns one `Session` (see Platform boundary); the behavior below is the session's, the controller only translates NSEvents and draws `View`. The macOS adapter runs the Zig core (through the C ABI) for keyboard parsing, composition state, trie-based phrase segmentation, and conservative one-key fuzzy rescue; it sends marked preview text and only committed text back to the client. Space is a boundary, never a commit: after pending keys it marks first tone — strong evidence like any tone key (other tones pay 4.0; RIME bopomofo parity, user decision 2026-09-27) — otherwise it stays a literal separator (empty composition passes it straight through); only Return commits — exactly the preview, raw Bopomofo tail included (注音文; a run that cannot start a syllable, like ㄏㄏㄏㄏ, stays raw whole), trailing whitespace trimmed; Shift+Return commits the keys as typed (`rawPhonetic`, never learned) for 注音文 made of valid syllables, like a lone ㄗ. Accepted text settles: earlier runs and words 3+ syllables before the end (one-character words 4+, since transient splits leave them behind; 2026-10-14) become character-level automatic pins (never learned, overridden by explicit picks), so the list only varies text near the cursor. Continuous toneless pending keys convert live as they are typed (`livePendingCut`: the whole run when it segments cleanly, else up to 3 trailing keys — the syllable in progress — stay raw), so tones stay optional and nothing waits for space; decode of a 57-key (26-syllable) toneless run measured ~90 ms per keystroke. They are jointly segmented in `decodeComposition`, fused tone-terminated runs are repaired onto the trailing piece, explicit tones are soft hints (same-base variants stay viable with a penalty, late tones re-hit via `retoneLast`), invalid readings get tiered edit repair (transpose 4.0, neighbor- and
phonetic-confusion substitute 5.0 — ㄧㄨㄩ / 捲平舌 / n-l / nasals ride
along even on valid bases, cost-capped so exact input keeps winning;
insert/delete 6.0 stay gated on no-clean-reading), and destructive editing
(plain Backspace erases one converted syllable when nothing is pending,
else one raw key; Option+Backspace one syllable, or a whole Latin word with
the spaces after it; Cmd+Backspace clears) never commits first. An explicitly picked candidate pins by text (Tab/arrows/
digit/click set `pinned_pick`): continued typing keeps the exact match, else
the first candidate extending it; only unmatched fresh evidence clears the
pin. A syllable cursor replaces the old Opt+Right segment lock (retired:
file-trace showed toneless input only beeped, fully toned input committed
exactly like Return). Plain Left/Right move the cursor over the converted
span — the caret parks at the focused word via marked-text selection and the
panel shows that span's options (`segmentOptions`, beam-independent trie
query); Tab/digit/click pin the choice into session-only `locked`
pins (reading-keyed decisive bonus, held till commit/clear/Escape, never
disk) and advance the cursor to the next word, Up/Down only move the
highlight. Return on a focused word pins the highlighted option if it
differs from the shown text, then ends the walk: caret back at the end,
however far back the cursor was (with return-confirms on, the next Return
commits; decision 2026-11-12 — Return used to pin-and-advance like a pick,
one press per word after the correction). Any
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
`Candidate.alignment` (syllable ↔ UTF-16 char ranges, rebased across
runs in `decodeSegments`) is the single source for caret placement and span
lookup; the cursor indexes the candidate's own decoded `syllables` (a toneless run is one fused syllable in the composition, so a rebuilt list never matched). The IME never reads surrounding text (`stringFromRange:` on the client): eager per-keystroke lookup segfaulted inside Chromium/Electron legacy client wrappers, offline decoding never needs it, and its only consumer (Jev) was removed 2026-10-09. Lexicon data: `script/prepare_lexicon.py` builds `lexicon.tsv` from pinned McBopomofo sources, then applies `Resources/reading_order.tsv` (hand-reviewed single-syllable top-1 swaps; stale rows fail the build); it also writes `toneless.tsv`, where single chars that share a toneless base swap score slots by NAER standalone frequency. `Lexicon.create(gpa, tsvs, toneless)` reads those scores only for a one-syllable span typed without a tone, so toned input and words never see them; `Lexicon.word_penalty` (0.5 as the C ABI and misstype-dev load it, 0 in a bare `Lexicon`) charges each dictionary word on a path, rebalancing word vs split-into-chars against McBopomofo's inflated single-char scores; `Resources/local_phrases.tsv` is concatenated at load. The IME binary is launched and supervised by TIS on demand — installers and scripts must never start it by hand, or the stray copy squats the `InputMethodConnectionName` Mach service and the TIS-launched instance fails to bind. Panel echoes are muted 150 ms around our own data-set/drive, and
refresh skips identical panel updates (`displayedTexts`) — the file trace
showed every keystroke's setCandidateData auto-firing Changed(first), which
used to drag selection back to 0; mid-composition Shift brush is ignored for
phonetic keys instead of committing, so fast typing never accepts early. A custom borderless `CandidatesPanel` (own NSPanel, vertical list, one page of `View.page_size` rows) mirrors the visible page: single source of truth for the highlight, so no IMK sync loop is possible. Auto-show (`Settings.auto_show_candidates`, macOS `MisstypeAutoShowCandidates`, default off; core/Linux default on) decides whether the panel opens while composing; off, it appears only once selection starts (Tab/Up/Down, syllable cursor; the symbol menu follows the same rule) and closes when selection ends. Return-confirms (`Settings.return_confirms_selection`, macOS `MisstypeReturnConfirmsSelection`, default on; core/Linux default off): while selecting (list, focused word, symbol menu) Return only confirms the pick and leaves selection, the next Return commits; off = Return commits at once. Backspace drops separator-derived pins (`settled_pins`, non-explicit `pinned_pick`) so erasing a space re-opens the full candidate list. The panel draws only rows (and the mark hint in its footer): the composition and its caret are the client's marked text (decision 2026-10-02: the earlier header that re-drew the preedit with our own `|` cursor marker was removed; a client that draws no marked-text caret now shows none). Down/Up step and enter selection mode; Tab/Shift+Tab and PageUp/PageDown turn pages (default bindings, decision 2026-10-05: Tab no longer steps one row; on a single page the first one only enters selection mode, then it beeps; Tab on a focused word pages its options instead of pinning, which selection keys and Return still do), where the selection keys (`MisstypePrefs.candidateKeys`, default home row `asdfghjk`; Zhuyin keys outside the mode, dim labels) and click pick; any other typing leaves the mode, the first Escape leaves it keeping the text, Return commits; Shift+digit is the full-width symbol layer (＠＃＄％︿＆＊（）＋｛｝～), not selection; plain Left/Right walk the syllable cursor back over the converted span — it indexes the top candidate's own decoded `syllables` (never a list rebuilt from the composition, where a toneless run is one fused syllable), the panel lists every word covering the cursor within its Zhuyin run (`cursorOptions`, longest first), and a pick pins only its span while earlier picks keep their characters outside it (`UserLexicon.pin`; session-only, any edit returns to end), Cmd+Left focuses the first word and Cmd+Right leaves the cursor walk without confirming, caret back at the end (bindable `cursorStart`/`cursorEnd`, decision 2026-11-12; with an empty composition they still go to the app), other modified arrows commit first and pass through; caret via `IMKTextInput.attributes(forCharacterIndex:lineHeightRectangle:)` walking back from marked end (McBopomofo-style, no permission needed — an Accessibility detour was tried and reverted the same day), falling back to last anchor then mouse. Preferences (`MisstypePrefs`: repairStrength, toneTolerance, candidateKeys, userLearning) are read live per keystroke from UserDefaults as a `Settings` snapshot and threaded through every decode entry point; the input menu opens the panel. Keyboard and panel options (decision 2026-10-05, issue #12): `Settings.page_size` (candidates per page, 4–10, default 8; selection keys address the first `pageSize` keys, the session pages by it and reports it in `View.page_size`), `keybindings` (`keybindings.zig`: per `Action` — 中/英 toggle, Down/Up step, pages (Tab/Shift+Tab and PageUp/PageDown), syllable cursor (plus first word / leave: Cmd+Left/Right), phrase mark, commit, raw commit, cancel, latin run — a list of `Chord`s or the defaults; `resolve` rewrites a bound chord into the action's canonical key before `type` runs, so the editing rules stay keyed on one key set; a removed default goes to the app, except Shift+Space, which becomes a plain Space; printable keys bind only with Control/Option/Command, editing keys never; explicit bindings win over another action's default; macOS stores the text form in `MisstypeKeyBindings`) (`-`/`=` also page while selecting; a selection key wins over them). `cursor_candidates` narrows the syllable cursor's list (vChewing's "cursor in front of / behind the phrase", checked against its source 2026-10-05): `covering` (default, every word covering the cursor syllable, caret before it), `ending_at` (macOS Zhuyin style: words ending after the cursor syllable, caret after it, so the first Left lists the last word) or `beginning_at` (Microsoft New Phonetic style: words starting at it, caret before it). Core defaults equal the previous fixed behavior. The panel look (`PanelStyle`: light/dark/system, a color scheme (`PanelTheme`: system colors with a neutral gray highlight, or Solarized, Nord, Gruvbox, Catppuccin, each with published light and dark palettes picked by the effective appearance; plus a user-defined one: four colors (background, text, selection key, highlighted row) for light and for dark, stored as `MisstypeCustomTheme` (`ThemeColors`, `bg,text,key,highlight` shared or `light|dark`), edited with color wells and hex fields in the theme gallery sheet `ThemeStudio`, which can start from a preset and copy/paste the text), font size 12–24 with row height scaled, separate font families for the words and the selection keys (`MisstypeCandidateFontFamily`, `MisstypeCandidateKeyFontFamily`; empty = system), a corner radius 0–20 (`MisstypePanelCornerRadius`; rows follow at radius − 4), and a grid layout showing up to 4 pages as columns: Up/Down walk the list across columns, Tab turns pages, only the current page's column is labeled with selection keys) is macOS-only presentation and never reaches the core, with one exception: in the grid Left/Right turn columns (pages, row kept, wrapping like Tab) while the selection keys are armed and the list has more than one page, and stay the syllable cursor otherwise (`Settings.arrows_turn_pages`, named setting `arrowsTurnPages`, set from `MisstypeCandidateGrid`; decision 2026-11-12: the cursor shows a word's list unarmed, so ← → keep walking words until Tab/Down arm the keys, and Esc gives them back; Cmd+Left/Right never turn columns). Settings has Appearance and Shortcuts panes for them. `IMKCandidates` proved undrivable (selectCandidateWithIdentifier: returns YES and moves nothing; synthesized stepping events only beep) and was removed. Punctuation literals and separator spaces pin the current pick and continue (no commit — Return owns that; tone-marking space with pending keys is unaffected). Latin runs work the same way via backtick-toggle (`L:`-marked keys, verbatim: letters and digits stay in the run, space too; punctuation or the toggle ends it), plus Shift-hold letters appending inline with no commit; a lone Shift tap mid-composition toggles the same latin run (no commit, no global flip — the 中/英 flip only happens with an empty composition and no run open). An open run survives Esc, Cmd+Backspace and delete-all (decision 2026-10-06: wiping text is not a vote for Zhuyin; only the toggle or a commit key closes it, and the tap that ends it is not a global flip). A run a Shift tap opened that is still open at Return becomes English mode after the commit (`KeyResult.mode_changed`; decision 2026-11-12: the tap flashes 英, so accepting quietly returned to 中 and the next keys came out as Zhuyin); a backtick run is an inline chunk and still closes. When the shown text is stranded Zhuyin (an unresolved syllable, or a raw tail longer than one syllable) the tap first re-reads the trailing Zhuyin keys as the letters typed (`Composition.convertTailToLatin`; tones become digits, Space stays) and leaves the run open, so English typed in the wrong mode needs no retyping and no `mixed_english`. Smart quotes (`Punctuation.smartQuote`) and the symbol menu (`SymbolMenu`, groups in `Punctuation.groups`; the typed mark is swapped in place via `Composition.replaceLastLiteral`) live in the session, not the adapters. Chunked auto-commit (`commitSettledHead`, `Settings.auto_commit_syllables`, default 24, `defaults write MisstypeAutoCommitSyllables`, 0 = off): once the shown sentence passes the limit, its head — whole words, all but the last `limit / 2` syllables — is returned as `KeyResult.commit` while the tail keeps composing; it only fires when the head is exactly what the keys said (no repairs or unresolved syllables) and no explicit pick, pin, cursor or open list exists, never trains learning, and consumes the head's raw keys. Backspace on a tone that closes a fused toneless body erases one decoded syllable, not the whole body. Backspace keeps an open latin run (and resumes one when it edits back into a latin tail), so fixing a typo needs no re-toggle. Clients that cannot show marked text (decision 2026-10-06, after vChewing's "mitigation level 2": Electron/WebView apps, detected by an `electron`/`mswebview`/`slimcorewebview` mark in Info.plist or `Frameworks/`, plus a built-in list and `MisstypePopupCompositionClients`) get a floating `CompositionPopup` below the caret with the preedit, caret and phrase mark, while the client receives a one-space placeholder as marked text so IMK keeps the composition alive and leaks no later keys; the blanket Electron rule (`MisstypePopupCompositionForElectron`) is OFF by default because several Electron apps (Obsidian) draw marked text fine; apps that do not are listed by bundle ID: built-ins plus a per-app input-menu toggle "Floating composition in this app" (`MisstypePopupCompositionClients` forces the popup, `MisstypeNativeCompositionClients` forces native and wins). The toggle exists because the broken case is a single element (t3code's terminal) inside an app whose other fields work, and the probe could not tell them apart (caret height 18 in the input vs 21 in the terminal was the only difference). Native-vs-popup cannot be detected at run time: after `setMarkedText` the working Obsidian and the broken t3code report identical `markedRange` / `attributedSubstring` / rect results (probe log, 2026-10-06), because those answer from the client's text model, not from what it paints. Marked text is sent as one clause segment per word (decision 2026-10-06, as vChewing/McBopomofo do): `View.segments` (UTF-16 ranges tiling the preedit, from the shown candidate's alignment, with Latin/punctuation gaps and the raw tail as their own segments) and `focus` (the syllable cursor's word); the IMK adapter gives each segment its own `markedClauseSegment` index with underline style 1, the focused word style 2 (thick), so clients draw a split underline. Candidate UI, preferences, and language switching belong at this boundary. 中/英 mode is a global `Engine.english` flag (one keyboard, all clients; Chinese on launch): Shift-tap and Shift+Space toggle, English passes keys straight through like a Latin IME, and a pill flashes plus the input menu shows the mode. Event inlet is raw `handleEvent` (vChewing parity, NOT `inputText`): the server takes the managed path whenever `inputText:key:modifiers:client:` exists and `handleEvent` never fires (verified 2026-09-18), so the controller omits it and parses NSEvents once — tap detection tracks Shift modifier state transitions with hold/cooldown guards, never event types (Electron duplicates cycles). The Zig core is the single source of truth for that behavior (see Principles).

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
The product logo (keyboard and tapping finger) is separate from the IME
icon: `MisstypeLogo.svg` (light), `MisstypeLogo-dark.svg` and the 1024 px
`MisstypeLogo.png` export. It is used by the Settings About pane, the website
(`site/icon.svg`, `site/editor/icon.png`) and the READMEs. The favicon
`site/favicon.svg` is a simplified 32-unit redraw (solid finger, no sparks)
because the full logo's strokes drop below a pixel at 16 px; the bundle, input
mode and menu icons above stay unchanged.

**App Sandbox (macOS, decision 2026-10-04, from vChewing's design).** The IME is signed with `Resources/Misstype.entitlements`: `app-sandbox`, `network.client` (Sparkle update checks and downloads; decoding opens no socket), `files.user-selected.read-only` (Settings → My Dictionary → Import… reads the one file the user picks; the merge goes into the editor and applies only on Save) and the `mach-register.global-name` exception for the IMK connection name (must equal `InputMethodConnectionName`). A sandboxed process cannot obtain a global keyboard tap, which backs the privacy stance. Consequences: `homeDirectoryForCurrentUser` resolves into `~/Library/Containers/org.misstype.inputmethod.Misstype/Data`, so the user files and the debug log live there (the paths in `cross-platform.md` §6 are container-relative); pre-sandbox files in the real home are not migrated (closed beta, never published). Anything outside the container needs a user-granted bookmark (not used yet). Verified on a real Mac (2026-10-04, ad-hoc signed build): IMK connection, typing and marked text, candidate panel, Settings Reveal in Finder, user dictionary save. Not yet verified: Developer ID signed/notarized build from `package_release.sh`.

## Core data contracts

The adapter contract is `misstype.h` (`misstype_key_event` → `misstype_key_result`, `misstype_view` or its JSON form); [`cross-platform.md`](cross-platform.md) defines how adapters apply it. Raw traces keep the capture format, one JSON object per line:

```text
RawEvent {
  session_id, sequence, timestamp_ns,
  surface: left | right,
  kind: touch_down | touch_move | touch_up | key | gesture,
  code?,             # BPMF:<key>, BPMF_FUZZY:<key>, LATIN:<text>, SPACE
  payload?           # touch: { x, y, layout, … } normalized to the surface
}
```

Use monotonic timestamps for ordering and a separate wall-clock field only for diagnostics. Sequence numbers make dropped or duplicated events detectable. `tools/misstype_dev.py` (`trace_input`) documents how a trace maps onto session keys or touch taps.

## Decode policy

### Chunked commit with mixed input

Chunked auto-commit operates on the settled, whole-word prefix even when the
composition has a later unresolved tail. The prefix is committed only when its
rendered word maps back to the exact captured phonetic keys; repaired words are
left in the composition for correction. Raw Latin runs (including text entered
with Shift) and exact automatic English spans are skipped while matching the
Chinese prefix, so a long mixed-language composition cannot make earlier safe
Chinese text stop committing. Automatic English spans carrying an edit remain
uncommitted until Return.

1. Keep every key; parse and segment without blocking capture.
2. Re-decode the whole composition on every key (live conversion); there is
   no debounce.
3. Commit on Return, or a settled head through chunked auto-commit.
4. Tone marks are optional hints: an exact-tone match commits at full
   confidence, a unique toneless match at reduced confidence, and an
   ambiguous toneless match stays a visible fallback for later repair.
5. Decoding is offline only. Remote assistance (Jev, an opt-in LLM
   re-ranker) was removed on 2026-10-09; LLM re-ranking remains a
   tools-only experiment (`tools/lm_choose.py`), never wired to the IME.
6. There is no asynchronous result to reconcile: decoding finishes inside
   the key event that triggered it.
7. User phrase learning (default on, opt-out in Preferences; local JSON
   only, never network): committing after an explicit pick
   (Tab/arrows/digit/click — never separator pinning) that corrected
   something records word-level (readings → text) pairs
   (`UserLexicon.learnedWords`): cursor picks of 2+ syllables still pinned
   at commit, words a whole-sentence pick changed versus top-1, or the input
   itself when it is one word. A pick that only confirms what was shown (top
   row) pins for the
   session but never trains words or the channel model (`learn_pins`;
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
   cursor, else the end); `View.mark` carries the UTF-16 range, the
   text, the toned reading and what Return will do. Return files the 2–8
   syllable span in `UserDictionary` (`user_dictionary.tsv`, sibling of
   `user_phrases.json`: `text reading [weight]` (vChewing userdata format; the legacy `reading<TAB>text` order is still read, decision 2026-10-04), `!` lines hide a
   built-in word) or, when the pair is already there, removes it; it never
   commits. `Engine.setUserDictionary` persists and calls
   `Lexicon.applyUserDictionary`, which writes the words into the trie
   as ordinary entries (default weight 0, above every built-in score) and can
   restore the built-in lexicon exactly; readings come from
   `Lexicon.readings`, the tone-exact path of the
   displayed word, so toneless typing still files toned readings. A mark may
   not cross punctuation/Latin or raw-Zhuyin text. The file is re-read when a
   composition starts if its mtime changed, so the macOS Settings "My
   Dictionary" pane (a text editor over the same file) and any external edit
   apply without a restart. Linux (fcitx5) gets the same behavior through the
   C ABI: `misstype_engine_set_user_dictionary_path` and the appended
   `misstype_view.mark_*` fields; the addon draws the mark as a highlighted
   preedit segment and the hint in the aux-down line (C13); the browser through
   `misstype_engine_set_user_dictionary_text`. Linux has a GTK4 editor, macOS
   a Settings pane, the web editor its own pane.
8. Syllable cursor (no modifiers): going back pins a word choice as a
   session-only decisive bonus (+1000, same overlay mechanism as learning
   but never persisted); the sentence still commits once at Return.

Remote input is opt-in and should be represented in the UI and event metadata. No remote call is required for correctness.

## Repository shape

```text
core-zig/src/         the core: session, composition, lexicon, touch, english, C ABI (capi.zig)
core-zig/src/tests/   behavior suites; core-zig/bench/ golden gates
Sources/              macOS: IMK adapter, Settings, installer, Swift bridge to the C ABI
linux/                fcitx5 addon, IBus engine, packaging (AUR, native)
packages/             misstype-wasm (JS binding), obsidian-misstype
site/                 landing page, demo and web editor (Vite)
tests/                fixtures, golden files, C ABI smoke, wasm and tool tests
tools/                replay, measurement and evaluation scripts (drive misstype-dev)
script/               build, install, release and check scripts
docs/                 decisions, status, lab notebook
```

## Failure and observability

Capture failures must be visible and recoverable without losing already-recorded events. Decoder failures fall back to the last offline result. Record structured metrics for event drops, queue depth, decode latency, timeout, confidence, and decoder source; never log raw text by default.

### Mixed-language decode

`english.mixedPass` (`english.zig`) reads bare keys as English when that wins on score: candidate English spans (exact words of an `EnglishLexicon` or one edit away for words of 5+ letters) are decoded as latin segments through `decodeSegments` and priced `word ln p - 6 x edits - switch_penalty` (default 4) against the all-Chinese reading. The English list is built by `script/prepare_lexicon.py` from the pinned FrequencyWords source into `.cache/frequencywords/english.tsv` and is optional: without it nothing changes. Measurements and limits are in the lab notebook ("Mixed Chinese/English without a switch").

Session wiring: after the live preview, `Session.refresh` calls `applyEnglish` when `Settings.mixed_english` is on and `Engine.english_lexicon` (loaded with the engine from `english.tsv`, or by `misstype_engine_load_english`) exists. The English reading is inserted first when it beats the Chinese one by `english.auto_margin` beyond the penalty, second within `suggest_window`, else not at all. Inserted readings are tracked in `complete_texts`: preedit shows no raw tail with them, and they are excluded from settled pins, `pinDifferences`, the syllable cursor (`focusFrame`), chunked auto-commit and learning, since their positional run indexes differ from the composition's. Punctuation, earlier latin keys and spaces in the composition are carried through unchanged; English spans are bare letter keys, optionally led by Shift-typed latin capitals (`Python`). Live readings show the syllable being typed as raw Zhuyin and charge `raw_key_cost` per raw key; a different extra letter after a whole word is never read as a typo. macOS default off (`MisstypeMixedEnglish`); core, C ABI and the browser binding default on when the word list is present.

### Developer word-model experiment (2026-10-14)

`word_lm.zig` reads complete word-pair counts with absolute-discount conditional
probabilities and add-one unigram backoff. The optional model interpolates its
log conditional probability with each lexicon entry score **inside** word-path
search, before beam pruning. Lexicon scores are heuristic scores, so this is
score interpolation, not interpolation of two normalized probability models.
Repair costs, user learning and locks retain their existing terms. At positive
weight this model replaces the later homophone PMI rerank; zero weight retains
it. The developer CLI alone loads `MISSTYPE_WORD_LM` with an explicit
`MISSTYPE_WORD_LM_WEIGHT`; platform adapters have no loader for this full model.
No model is bundled and defaults stay unchanged. Interactive prefixes use BOS
but no EOS bonus. Unknown words use UNK; unknown Chinese glyphs in training are
mapped to UNK. The existing beam and per-reading entry cap still bound recall.
Model counts and source provenance are generated locally by `tools/word_lm.py`;
fixed dev comparisons run through real Sessions with `tools/eval_word_lm.py`.


### Repair picks and captured readings (2026-10-14)

A positional Session pick is keyed by the captured, toneless reading at its
run-local character offset. Decoder paths may use repaired dictionary readings;
they also check the captured span key for positional pins and entry-cap bypass.
This honors explicit repair choices without replacing raw keys or changing edit
costs. Legacy dictionary-reading lookup remains compatible. Reproduction,
paired typing results and intentional replay updates: [repair-pick.md](repair-pick.md).


### Optional sparse word model (experimental)

The offline decoder accepts the full `MWLM` table and `MSLM` v1 through
`word_model.Table`. MSLM stores sorted hash/unigram/backoff word records
(16 bytes) and sorted vocabulary-ID/direct-mass pairs (12 bytes). Pruning
transfers deleted probability mass to unigram backoff; parsing validates
normalization and special symbols. The scorer and repair search are shared.

The C ABI (and so the wasm module) exposes `misstype_engine_load_word_model(engine, ptr, len, weight)` for explicit
experiments only: MSLM, at most 8 MiB, finite weight in [0,1], one successful
load per initialization. The decoder owns a copy; the upload buffer can be
freed. A positive weight replaces homophone reranking. The JS URL loader
falls back to the existing optional homophone table on failure. No model or
new weight becomes a shipping default. Results and limitations are in
[lightweight-models.md](lightweight-models.md).
