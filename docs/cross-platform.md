# Cross-platform IME contract

How Mistype runs on more than one OS without forking behavior. This is the
normative contract every platform adapter follows; `docs/linux-port.md` is the
task plan that applies it to Linux (fcitx5).

## Layers

```text
┌───────────────────────── MistypeCore (Swift, all platforms) ─────────────────────────┐
│ LexiconDecoder · Composition · LivePreview · UserLexicon · Punctuation · Jev          │
│ InputEngine (per process) · InputSession (per client) · KeyEvent · key tables         │
└───────────────┬───────────────────────────────────────────────┬───────────────────────┘
                │ Swift API                                     │ C ABI: CMistype/include/mistype.h
                │                                               │ implemented by MistypeCAPI (@_cdecl)
┌───────────────▼──────────────┐              ┌─────────────────▼───────────────────────┐
│ macOS: MistypeIME (IMK)      │              │ Linux: linux/fcitx5 (C++ addon)         │
│ NSEvent → KeyEvent           │              │ fcitx::KeyEvent → mistype_key_event     │
│ SessionView → marked text,   │              │ mistype_view → client preedit,          │
│ CandidatesPanel              │              │ CommonCandidateList                     │
└──────────────────────────────┘              └─────────────────────────────────────────┘
                                   future: IBus, Windows TSF — same C ABI
```

**Rule: behavior lives in the core; adapters only do I/O.** An adapter
translates native key events, applies `KeyResult`, draws `SessionView`, and
owns platform lifecycle, UI, preferences storage and file locations. If an
adapter change would alter what a key sequence produces, the change belongs in
`InputSession` (with an `InputSessionTests` case) instead.

The Swift adapter (macOS) calls the Swift API directly. Every non-Swift
adapter goes through the C ABI; `mistype.h` is its only interface to the core.

## The contract

### 1. Key translation

- Physical keys are named by their **US-ANSI unshifted label** (`"a"`, `"1"`,
  `";"`, `` "`" ``), never by the character the user's layout produces: the
  大千 Zhuyin layout is positional.
- Key-code tables are data in the core (`MacKeyCode`, `EvdevKeyCode`) so they
  are unit-tested on every platform. Adapters never carry their own table.
- When an event has no scancode (virtual keyboards, synthetic events), fall
  back to `USLayout.key(forCharacter:)` on the event's text.
- `text` is what the key types in the user's current layout, case included
  (Shift+A → `"A"`); `nil`/`NULL` when the key types nothing.
- `modifiers` is the modifier state **after** the event: a Shift press carries
  Shift, its release does not. (X11/fcitx5 report the state before the event;
  the adapter corrects Shift keys.) Option = Alt, Command = Super.
- `.release` (`is_release = 1`) is key-up and modifier-only transitions.
  Releases only feed lone-Shift tap tracking.

### 2. Applying a `KeyResult`

In this order, for every press:

1. If `modeChanged`: capture the indicator anchor from the preedit **currently
   drawn** (before step 2 removes it).
2. If `commit` is non-nil: insert it into the client. Inserting replaces the
   client's marked text, so record the drawn preedit as empty (do not send an
   extra empty preedit).
3. Render `session.view` (§3).
4. If `beep`: signal it where the platform has a convention (macOS beeps;
   fcitx5 has none — ignore).
5. If `modeChanged`: show the 中/英 indicator.
   If `latinToggled` (a latin run opened/closed mid-composition; macOS shows it,
   fcitx5 may ignore it): flash the same indicator, 英 while `latinActive`, 中 once closed.
6. Report the key as handled iff `consumed`, subject to the platform delivery
   rules below.

`consumed == false` means the application must receive the key **after** the
commit text: e.g. Cmd/Ctrl+C with a composition commits the preview, then the
shortcut runs.

### 3. Rendering `SessionView`

- Render after every call that can change state (`handle`, `pick`, `commit`,
  and `sessionDidChange`). Skip when the view equals the last drawn one.
- Preedit: `preedit` with the caret at `caret` (UTF-16 in Swift;
  `caret_bytes`/`caret_utf16` in C — use whichever unit the platform takes;
  fcitx5 `Text::setCursor` is **bytes**). The caret is the focused-word start
  in cursor mode, else the end.
- Candidates: show iff `showsCandidates`. `candidates` is the full list; page
  it 8 per page with the page containing `selected` visible and `selected`
  highlighted. Label visible rows with `selectionKeys`; dim or hide labels
  when `keysActive` is false (selection keys type Zhuyin then).
- Page keys: translate PageUp/PageDown to `MISTYPE_KEY_PAGE_UP/DOWN` (ABI
  values 15/16, appended); the core pages the highlight, the host just
  redraws the page holding `selected`.
- A click/tap on row `i` of the full list calls `pick(at: i)`, then render.
- Never mutate or reorder the list: the session owns the highlight.

### 4. Lifecycle

- One `InputEngine` per process (shared decoder, learning, 中/英 mode,
  Shift-tap state). One `InputSession` per input context/client.
- Focus in / activate: `resetModifierState()`.
- Focus out / deactivate / client reset: `commit()`; insert the returned text
  if non-nil; render.
- The platform's "original string" query returns `rawPhonetic`.

### 5. Threading and host callbacks

- All calls for one engine and its sessions happen on one thread (the
  platform's UI/event-loop thread). The core is not thread-safe.
- `InputSessionHost` (Swift) is optional. With no host, remote (Jev)
  evaluation can never run: the offline baseline needs nothing from the host.
  `surroundingContext()` must only be called by the core, and only when a Jev
  request will be attempted (macOS clients have crashed inside
  surrounding-text calls). The C ABI v1 has no host callbacks: Jev is off on
  non-Swift adapters until a task adds them.

### 6. Resources, data and settings

| | macOS | Linux (fcitx5) |
|---|---|---|
| Lexicon dir (`LexiconLoader`) | `MistypeIME.app/Contents/Resources` | `/usr/share/mistype` (compiled-in), `MISTYPE_RESOURCES` overrides |
| My words (`UserDictionary.defaultURL`) | `~/Library/Application Support/Mistype/user_dictionary.tsv` | `$XDG_DATA_HOME/mistype/user_dictionary.tsv`; the host calls `mistype_engine_set_user_dictionary_path(engine, NULL)` (default after `_new` is memory only) |
| Learned phrases (`UserLexicon.defaultURL`) | `~/Library/Application Support/Mistype/user_phrases.json` | `$XDG_DATA_HOME/mistype/user_phrases.json` (default `~/.local/share`) |
| My-words editor | Settings → My Dictionary (text editor over the file) | none yet: edit the TSV in any editor, reloaded at the next composition |
| Settings store | UserDefaults (`MistypePrefs`) | defaults in v1 (`mistype_settings_default()`), fcitx5 config later |
| Lone-Shift 中/英 | session (`shiftToggle` pref, default on) | fcitx5 `AltTriggerKeys` (default `Shift_L`) → session `shift_toggle = 0` |
| Diagnostic log | `~/Library/Logs/MistypeIME-debug.log` | none in v1 (codes only, never text, if added) |

Resource files are identical on every platform: `lexicon.tsv` (required),
`local_phrases.tsv`, `toneless.tsv`, all produced by
`script/prepare_lexicon.py`. The learned-phrase JSON is portable across
platforms.

### Platform delivery rules

| Situation | macOS (IMK) | Linux (fcitx5) |
|---|---|---|
| Key release / modifier-only change | return `consumed` (always true) | pass to the session, **never** `filterAndAccept()` |
| Bare modifier press (Ctrl alone…) | return `consumed` (true) | pass to the session, **never** filter |
| Any other press | return `consumed` | `filterAndAccept()` iff `consumed` |
| Focus out with a composition | `commit()`, insert | fcitx5 itself inserts client-side preedit on focus out: the engine only clears its session (a second insert would duplicate the text). Without client preedit, or when switching input method, the engine inserts. Client `reset` discards |

Filtering releases or bare modifiers on X11/Wayland can desynchronize the
application's own modifier state; the session never changes the composition
on those events, so not filtering them is safe.

## Conformance scenarios

Every adapter's integration tests implement these against the fixture lexicon
`tests/fixtures/lexicon/lexicon.tsv` (7 lines, identical to the inline fixture
in `InputSessionTests`):

```text
ㄋㄧˇ	你	-5
ㄋㄧˇ	妳	-6
ㄋㄧˇ	尼	-7
ㄋㄧˇ	泥	-8
ㄏㄠˇ	好	-5
ㄋㄧˇ-ㄏㄠˇ	你好	-3
ㄇㄚ˙	嗎	-4
```

Keys are physical labels; `⏎` is Enter. "Passes" means the application
receives the key (`consumed == false` / not filtered). The Swift reference for
each is the named `InputSessionTests` case.

| ID | Keys | Expected | Reference |
|---|---|---|---|
| C1 | `s u 3 c l 3` then `⏎` | preedit `你好`, caret at end (UTF-16 2, bytes 6); `⏎` commits `你好`, preedit empty, no candidates | `testTypingConvertsLiveAndReturnCommitsThePreview` |
| C2 | empty: `⏎`, `Backspace`, `Left`; then `Space` | first three pass with no commit; `Space` commits `" "` and is consumed | `testEmptyCompositionPassesKeysThrough` |
| C3 | `s u 3 c l 3`, `Backspace` | preedit `你`, nothing committed | `testBackspaceEditsWithoutCommitting` |
| C4 | `s u 3`, `Tab`, `d`, `⏎` | candidates shown; after `Tab` selected 1 and selection keys active; `d` picks row 2 → preedit `尼`; `⏎` commits `尼` | `testTabSelectsAndSelectionKeysPickThenLearn` |
| C5 | `s u 3`, `Down`, `Esc`, `Esc` | preedit `妳`; first `Esc` keeps `妳` and leaves selection; second clears with no commit | `testEscapeLeavesSelectionFirstThenClears` |
| C6 | `s u 3`, Shift+`,`, Shift+`a`, `⏎` | preedit `你，` then `你，A`; commits `你，A` | `testPunctuationAndShiftLatinStayInsideTheComposition` |
| C7 | `s u 3`, backtick, `h i` | preedit `你hi` | `testBacktickLatinRun` |
| C8 | `s u 3 c l 3`, `Right`, `Left` | `Right` consumed without change (beep); `Left` enters cursor mode: candidates shown with `你好` first, selection keys active, caret UTF-16 1 / bytes 3 | `testSyllableCursorFocusesAWord` |
| C9 | `s u 3`, Ctrl+`c` (macOS: Cmd+`c`) | commits `你`, then the key passes | `testChordsAndCapsLockCommitThenPassThrough` |
| C10 | `s u 3`, Shift+`Space`, `s` | Shift+Space commits `你` and flips to English (mode indicator); `s` passes | `testShiftSpaceTogglesEnglishCommittingFirst` |
| C11 | `s u 3`, focus out | commits `你` | `testPanelPickAndHostCommit` (host commit) |
| C12 | `s u 3`, click row 3 | preedit `泥` | `testPanelPickAndHostCommit` |
| C13 | `s u 3 c l 3`, Shift+`Left` ×2, `⏎` | after the arrows `view.mark` = range UTF-16 0..<2, text `你好`, reading `ㄋㄧˇ-ㄏㄠˇ`, action `add`, no candidates but `showsCandidates`; `⏎` is consumed with no commit, the mark clears, preedit stays `你好`, and the user dictionary holds the pair | `testConformanceC13MarkAndFileAPhrase` |

A new adapter is conformant when all thirteen pass headlessly in CI (Linux: the
fcitx5 `testfrontend` harness). Behavior that differs from this table is a
core bug or an intentional contract change — never an adapter special case.

## Adding a platform

1. Key table in the core (`<Platform>KeyCode`, same label set as
   `MacKeyCode`, unit-tested).
2. Adapter over the Swift API (Swift platforms) or `mistype.h` (everything
   else), following §1–§6 and the delivery rules.
3. Headless integration tests for C1–C13.
4. Resource/data locations added to the §6 table.
5. A row in the delivery-rules table if the platform's event model differs.

## Known costs

- The Linux C ABI library links the Swift runtime and Foundation statically:
  `libMistypeCAPI.so` is ~71 MB (~56 MB stripped; measured 2026-09-28,
  aarch64), mostly Foundation's ICU data. It has no Swift runtime dependency
  at install time; it does need `libcurl.so.4` (FoundationNetworking, used by
  `JevClient`), which every mainstream distro ships.
