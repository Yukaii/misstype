# Enabling the IME on other websites

`packages/misstype-wasm` (0.2.0) can switch the Misstype decoder on for any page's
text fields, for places where no native IME can be installed (iPad with a hardware
keyboard, locked-down or shared machines, Chromebooks) and a site wants to offer
Zhuyin itself.

```html
<script type="module" src="https://your-host/embed.js"></script>
```

`npm run build` in `site/` emits `dist/embed.js` (one ES module with the wasm shim
bundled, from `packages/misstype-wasm/src/embed.js`) beside `misstype.wasm`,
`lexicon.tsv`, `toneless.tsv` and `english.tsv`; the script finds those by its own
URL. Pages serves them with `Access-Control-Allow-Origin: *`, so another site can
load the published copy, or host the five files itself. Options and the `enable()`
API are in the package README.

## How it works (`src/enable.js`)

- One wasm session, one set of capture-phase listeners on `document`
  (`keydown`, `keyup`, `pointerdown`, `focusout`, `compositionstart`), so fields
  added later work and no per-element setup is needed. Target test: `closest()`
  of the selector, not password/email/number types, not disabled/read-only, not
  `inputmode="none"`, not `data-misstype="off"`.
- Keys the decoder consumes get `preventDefault` + `stopImmediatePropagation`;
  Ctrl/⌘ shortcuts, Home/End, pointer moves and blur first commit the pending
  composition. Ctrl+J/K stay with the decoder. A system IME (`isComposing` or
  keyCode 229) is left alone; `onNativeIme` reports it.
- Finished text goes in with `document.execCommand("insertText")`, falling back to
  `setRangeText` plus an `input` event, so undo and framework change handlers see
  an ordinary edit.
- Pre-edit and candidates are drawn in a floating window (shadow root, so page CSS
  cannot touch it) anchored at the caret: contenteditable uses the selection
  range, `<input>`/`<textarea>` a mirror element. They are not written into the
  field, so the field's value only ever holds finished text.
- The user dictionary is the desktop format (`user_dictionary.tsv`), kept in
  `localStorage` (`storageKey`), saved when its word count changes.

## Checked

Headless Chromium with the script loaded cross-origin (page on one port, `embed.js`
and assets on another): an `<input>`, a `<textarea>` and a `contenteditable` each
received 你好 from `su3cl3` + Enter with `insertText` input events, a password
field was left alone, and a Shift tap switched to English with the flash. Not yet
tried: Safari/iPad, cross-origin iframes, pages with their own capture-phase key
handlers, rich editors that manage their own DOM (ProseMirror, Lexical, Slate;
use the low-level API as `site/editor/` does).
