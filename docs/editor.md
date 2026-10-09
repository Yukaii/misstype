# Markdown editor (web, offline PWA)

`site/editor/` — a Wordgard rich-text editor with the Misstype wasm decoder
attached. It exists because iPadOS lets web pages and apps use only Apple's
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
  keys never reach Wordgard. Keys the decoder ignores (English mode, arrows,
  Enter with no composition) fall through to Wordgard.
- The pre-edit text and candidates live in a floating bar anchored at the
  caret (`candidates.js`, styled by `site/playground.css`), not inside the
  document. Finished text is inserted with Wordgard's `insertText` command,
  so undo and input rules behave normally. Ctrl/⌘ shortcuts and pointer
  moves first commit the composition.
- Documents are stored as Wordgard JSON in `localStorage`; Markdown is
  generated on demand (`markdown.js`, tested by
  `tests/editor_markdown_test.mjs`). The raw trace is not recorded here.
- Settings (`settings.js`): candidates per page, Shift toggle, Enter confirms,
  auto-show candidates (all passed to the wasm session), candidate layout and
  palette, font size, column width.

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
too), `Mod-,` settings. `Ctrl-J/K` stay with the decoder.

## Known limits

- In Chinese mode the decoder owns `-`, `#`, `*`, backtick and digits, so
  Markdown shortcuts (`# `, `- `, `**bold**`) only trigger in English mode;
  the toolbar and palette work in either.
- The pre-edit is not drawn inline in the text.
- No Markdown import; paste is Wordgard's (HTML/plain text).
- Not tried on a real iPad or in an installed home-screen app; the offline
  path is verified with Chromium only.
