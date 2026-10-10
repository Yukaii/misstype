# Markdown editor (web, offline PWA)

`site/editor/` — a ProseMirror Markdown editor (`prosemirror-markdown`'s
schema) with the Misstype wasm decoder attached. It exists because iPadOS lets web pages and apps use only Apple's
keyboards: a hardware-keyboard user cannot install a custom IME, but a page
that owns its text field can run the decoder itself.

Hypothesis: the same core that powers the macOS and Linux IMEs gives an iPad
hardware-keyboard user the Misstype editing model (live conversion, syllable
cursor, fuzzy repair) inside a page. Falsified if the decoder cannot see
physical key events on iPad Safari (checked so far only with Playwright's
iPad emulation, not a real device).

## How it fits

- Keys are captured on the editor in the capture phase (`editor.js`
  `keyDown`), sent to `misstype-wasm` (`packages/misstype-wasm`), and consumed
  keys never reach ProseMirror. Keys the decoder ignores (English mode, arrows,
  Enter with no composition) fall through to ProseMirror.
- The pre-edit text is drawn inside the document at the cursor, as in the
  landing page playground: a ProseMirror widget decoration (`preedit.js`)
  that is never part of the document, so history, saving and copying only
  see finished text. A selection the pre-edit replaces is hidden, and comes
  back if the composition is cancelled. The candidate window (`candidates.js`,
  styled by `site/playground.css`) hangs under the pre-edit caret.
  Finished text is inserted with `tr.insertText`; Ctrl/⌘ shortcuts, toolbar
  taps and pointer moves first commit the composition.
- Notes are stored as Markdown in `localStorage` and parsed back on load, so
  the saved note, the copied text and the downloaded `.md` are the same
  (`model.js`, tested by `tests/editor_markdown_test.mjs`). Pasted plain text
  is parsed as Markdown, and the palette can import a `.md` file. The raw
  trace is not recorded here.
- The toolbar (`index.html`, `editor.css`) uses the page's colour variables,
  so it follows the light/dark switch.
- Settings (`settings.js`): candidates per page, Shift toggle, Enter confirms,
  auto-show candidates (all passed to the wasm session), candidate layout and
  palette, font size, column width.

## My Dictionary

The same file format and pane as the desktop apps (`user_dictionary.tsv`:
`text reading [weight]`, `!text reading` hides a built-in word): a plain-text
editor with live validation (line-numbered problems, word and hidden counts),
Import (merges vChewing user data into the box), Export, Revert and Save.
Open it from the palette (`Mod-Shift-D`) or Settings. The wasm module has no
files, so `misstype-wasm` gained `userDictionaryText/Count`, `setUserDictionary`,
`checkUserDictionary` and `importUserDictionary` (core: `wasm.zig`, tested in
`packages/misstype-wasm/test`); `dictionary.js` keeps the text in
`localStorage` and re-applies it at start. Marking a phrase with Shift+←/→
highlights it in the pre-edit with an Enter hint, and Return files it; the
editor notices the count change and saves the canonical text (which drops
comments, as on desktop). Opening Settings focuses the candidates-per-page
select (list closed).

## Learning

Settings has a 學習 group: remember explicit candidate picks (`userLearning`,
default on) and learn typing slips (`channelLearning`, experimental, needs the
first). 管理⋯ (or the palette's 學習資料) opens a pane listing the learned
phrases (reading, text, count) with per-phrase 忘記, Import/Export of the
desktop `user_lexicon.json`, Clear, and the learned slips (`ㄥ → ㄣ`, about how
often) with Clear. The wasm module has no files, so it exposes
`learningRevision`, `learnedData`/`loadLearned`, `channelData`/`loadChannel`
and friends (core: `wasm.zig`, `Engine.learning_revision`); `learning.js`
saves both JSON blobs to `localStorage` when the revision changes and restores
them at start. The drop-in layer (`enable`, `embed.js`) does the same with
`learningKey` (default `misstype-learned`, slips in `misstype-learned-slips`,
shared with this page when on the same origin) and exposes `learned()`,
`forgetLearned`, `clearLearned`, `clearSlips`. Before this, picks were learned in memory but lost on reload.
Checked with the wasm tests and a production build; the pane itself has not
been driven in a browser yet.

## On-screen keyboard

Touch devices without a keyboard (`(pointer: coarse) and (hover: none)`) get
a mini QWERTY with a number row (`keyboard.js`, layout and cap labels in
`vkeys.js`, tested by `tests/editor_vkeys_test.mjs`). Keys carry the standard
Zhuyin layout: Zhuyin large with the Latin letter as a corner hint. Holding
Shift (second thumb) swaps the caps to uppercase letters and shifted symbols;
a lone Shift tap is the usual 中/英 toggle, and the caps follow the decoder's
mode. Presses are replayed as `KeyboardEvent`s on the editor, so the decoder,
settings and ProseMirror keymaps see what a hardware keyboard would send;
unclaimed printable keys are inserted as text. The system keyboard is
suppressed with `inputmode="none"` while ours is up. Backspace repeats.
Settings → 螢幕鍵盤: auto (default), always, off. In auto the keyboard hides
once a real key event arrives (iPad with a hardware keyboard).
Checked with the unit test and a production build only; not yet driven on a
phone or in an emulator.

## Offline

`vite.config.js` (`editorPwa`) emits `editor/sw.js` with the list of built files
(JS, CSS, wasm, lexicons, icons) and `manifest.webmanifest`. The worker answers
from its cache first and refreshes in the background; a new build changes the
cache name and drops the old one. Registered in production builds only.
Nothing typed is sent anywhere.

## Commands and keys

Command palette: `Mod-Shift-P` (or F1, or the 指令 button). Also
`Mod-Shift-C` copy Markdown, `Mod-Shift-X` copy plain text, `Mod-Shift-K` clear
(undoable), `Mod-S` download `.md`, `Mod-Shift-E` toggle 中/英 (a Shift tap
too), `Mod-,` settings. The 中/英 mode flashes beside the cursor when it changes, including a Shift tap or backtick that opens or closes an English run inside a Chinese composition (as on desktop) and is shown in the status strip; there is no header button for it. `Ctrl-J/K` stay with the decoder.

## iOS 26 Safari chrome

Safari 26 draws the page edge to edge under translucent bars and tints them
from the page background or a sticky/fixed element at the edge (`theme-color`
is unreliable there). So `editor.css` keeps `html`, `body`, the sticky
header/toolbar and the status strip all `--paper`, puts the safe-area insets on
those bars instead of the body, and scrolls the window rather than an inner
box; `keepCaretClear` sets ProseMirror's scroll margins from the bar heights.
Checked only with Chromium's iPad emulation (no safe-area insets there).

## About

An About dialog (status strip, or the palette) says what the page is for: the same
IME inside a web page, for devices that cannot install a custom one, with links to
the native macOS and Linux versions and the privacy note.

## Known limits

- In Chinese mode the decoder owns `-`, `#`, `*`, backtick and digits, so
  Markdown shortcuts (`# `, `- `, `**bold**`) only trigger in English mode;
  the toolbar and palette work in either.
- The Markdown schema has no strikethrough, tables or task lists.
- The on-screen keyboard has no key-preview popup, one-shot Shift (tap Shift then a letter) or number/symbol layers; Shift is hold-only because a tap is 中/英.
- Not tried on a real iPad or in an installed home-screen app; the offline
  path is verified with Chromium only.
