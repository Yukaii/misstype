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
  is parsed as Markdown, and the palette can import a `.md` file (as a new
  note). The raw trace is not recorded here.
- Several notes (`notes.js`, tested by `tests/editor_notes_test.mjs`): an
  index `misstype-editor-notes` (folders, order, titles, last open note) plus
  one key per body, `misstype-editor-note:<id>`. The single note of earlier
  versions (`misstype-editor-md`) becomes the first note. Folders are one
  level deep (PARA: the palette's "建立 PARA 資料夾" adds Projects, Areas,
  Resources, Archives); a title is the note's first line. Each change re-reads
  the index, so two tabs do not overwrite each other's notes; the open note
  is per tab, and each note keeps its own undo history for the visit.
- Layout: the notes sidebar is a top-level, full-height column beside the
  editor pane (`site/editor/index.html` `.shell`), not part of the pane's
  header/toolbar frame. The pane's header keeps four things: the sidebar
  toggle, the current note title (tap to open the switcher), the command-palette
  button and a ⋯ menu for document and app actions (copy Markdown / plain
  text, zen, settings, theme, clear). The sidebar carries the app brand and a
  prominent 新增筆記 button.
- Sidebar (`sidebar.js`, `Mod-\`): docked on screens wider than 800px (open
  or closed is remembered), a drawer over the whole window elsewhere, with a
  close button in its header. Each row has a ⋯ menu (move, delete; folder:
  new note, rename, delete — its notes move to the top level); a note can be
  dragged onto a folder or before another note. Folder names use the system
  keyboard, not the decoder.
- ←/→ on iOS (`actions.js` `horizontalKeys`): Safari on an iPhone with a
  hardware keyboard did not move the caret for plain ←/→ here (↑/↓ worked;
  the decoder passes all four on when nothing is composed, and ProseMirror
  leaves plain text to the browser). The root cause in WebKit is not pinned
  down; on iOS the editor moves the caret itself: one code point, into the
  neighbouring textblock at an edge, Shift extends
  (`tests/editor_arrows_test.mjs`). ⌥/⌘ moves stay native.
- Quick switcher (`Mod-P`, or the palette's "切換筆記⋯"): the palette over
  the notes, most recently edited first (the open one last), matching the
  title and the folder name.
- Zen mode (`zen.js`, `Mod-Shift-F` or the header's ⋯ menu): hides the
  header, toolbar, status strip and sidebar, and dims every block but the cursor's
  (and the list item / quote holding it). Esc (when no composition takes
  it), the command or the faint corner button leave it.
- The toolbar (`index.html`, `editor.css`) uses the page's colour variables,
  so it follows the light/dark switch. Unlike the landing page (light until
  chosen) the editor follows the system until a scheme is picked
  (`data-theme-default="auto"`), and `theme-color` follows the scheme in
  effect: Safari tints its bars with it, which showed a dark bar over the
  fixed light page.
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
a Zhuyin keyboard laid out like iOS's (rows of 11, 10, 10 and 11 keys, rows two and three staggered, Shift / space / Enter below; `keyboard.js`, layout and cap labels in
`vkeys.js`, tested by `tests/editor_vkeys_test.mjs`). Keys carry the standard
Zhuyin layout: Zhuyin large with the Latin letter as a corner hint. Holding
Shift (second thumb) swaps the caps to uppercase letters and shifted symbols;
a lone Shift tap is the usual 中/英 toggle, and the caps follow the decoder's
mode. Presses are replayed as `KeyboardEvent`s on the editor, so the decoder,
settings and ProseMirror keymaps see what a hardware keyboard would send;
unclaimed printable keys are inserted as text. The system keyboard is
suppressed with `inputmode="none"` while ours is up. Backspace repeats and, when neither the decoder nor a keymap takes it, deletes
the selection or the character before the caret itself (a synthetic event has
no browser default). With the keyboard up the candidates dock above it as one row of all
candidates that scrolls sideways (`.candidate-panel.docked`, as in the system
candidate bar) instead of floating at the caret; the page arrows are hidden.
The bar keeps its slot, so the stack is keyboard, candidate bar, status strip.
While the keyboard is up the body leaves room for it and the candidate bar
(`body.vk-on`); the document scrolls in the space between (see iOS 26 Safari
chrome below).
A chevron at the bar's right end dismisses the keyboard (it commits the
pre-edit and blurs the editor, text stays); the keyboard comes back when the
editor takes focus again, and `inputmode="none"` stays so the system keyboard
never appears in between.
Keyboard taps keep the editor focused; a blur they cause never commits the
pre-edit, so Shift behaves as on a hardware keyboard. A pressed key shows a preview bubble. The look follows
the platform (`data-platform`, from the user agent): iOS-style keys by
default, Gboard-style rounded keys and a tinted Enter on Android; both follow
the light/dark switch.
Key presses give a haptic tick (`haptics.js`, setting 按鍵震動回饋, default on):
`navigator.vibrate` on Android, and on iOS Safari 17.4+ a hidden
`<input type=checkbox switch>` clicked from the handler (undocumented; silent
if unsupported). Neither has been felt on a real device yet.
Settings → 螢幕鍵盤: auto (default), always, off. In auto the keyboard hides
once a real key event arrives in the editor (iPad with a hardware keyboard),
and that is remembered (`localStorage` `misstype-hardware-keyboard:2`) so it
does not come back on the next load. Keys typed into a text field (note
rename, palette, dictionary) do not count: the system keyboard sends real
keydowns there too (Latin letters, Backspace, Return), and counting them hid
the on-screen keyboard for good after renaming a note (`fromHardwareKeyboard`
in `keyboard.js`; the old key is dropped on load to clear those). Picking "auto" again in Settings forgets it. The very
first visit still shows the keyboard until one real key is pressed: a page
cannot ask whether a hardware keyboard is attached.
The status strip's 鍵盤 switch is the manual override, on every device. It
writes `on` or `off` to the same setting, applies at once and survives a
reload (the pressed pill means the keyboard is up); choosing 自動 in Settings
restores detection. That matters where the heuristic cannot be sure: a
touchscreen laptop with a mouse stays out of auto, an iPad whose Magic
Keyboard trackpad makes the primary pointer fine can flip auto's
`(pointer: coarse) and (hover: none)` query, and detaching a hardware keyboard
leaves `hardwareKeyboardSeen` set. The palette has the same command
(顯示／隱藏螢幕鍵盤). Switching it off does not hand the keys back to the
system input method when a hardware keyboard was seen: `inputmode="none"`
stays, so the decoder still owns typing and the page's 英 mode works (an iPad
with a Magic Keyboard and a system Zhuyin input otherwise turns English into
Bopomofo). On a touch-only device `off` lets the system keyboard in, as that
is the only input left.
The visibility matrix is unit-tested and the switch was driven in Chromium
with the keyboard forced on; neither has been driven on a phone or iPad yet.

## Offline

`vite.config.js` (`editorPwa`) emits `editor/sw.js` with the list of built files
(JS, CSS, wasm, lexicons, icons) and `manifest.webmanifest`. The worker answers
from its cache first and refreshes in the background; a new build changes the
cache name and drops the old one. Registered in production builds only.
Nothing typed is sent anywhere unless the user connects a cloud account (Cloud
sync below); the worker only handles same-origin requests, so sync traffic is
never cached.

## Cloud sync

Decision 2026-10-25: the editor can sync its notes and folders to the user's
own Dropbox or Google Drive, so the same notes follow them between an iPad, a
phone and a desktop browser. This is the one exception to "sync is deferred"
in `docs/project-outline.md`: it is opt-in, off until an account is connected,
goes straight from the browser to the user's storage (no server of ours, no
account with us), and the notes stay usable offline.

Hypothesis: per-note Yjs documents for text and a workspace Yjs document for
organization, carried as static files, are enough for one person moving between
devices: no text is lost, concurrent edits merge without a relay, and changes
show up within a couple of minutes. Falsified if a normal
edit/switch-device/edit cycle loses text, duplicates a note, or needs manual
merging more than rarely.

- What syncs: note bodies and the workspace around them — the folder list,
  each note's folder, and folder/note order. Not settings, My Dictionary or
  learning data (follow-ups; the dictionary and `user_lexicon.json` share the
  desktop file formats, which could later let a desktop app read the same
  folder). A new note from another device lands at the top of its folder.
- Remote layout (`sync.js`, `workspace.js`, `content-sync.js`): the body
  export stays `notes/<id>.md`, the Markdown behind a short front matter
  (`misstype: 1`, `folder`, `updated`); a `.md` file dropped into `notes/` by
  hand becomes a top-level note. Organization is `workspace.<device>.json`,
  one file per device, holding `{v, device, state: base64(Y.Doc)}`. A note's
  text CRDT has one immutable seed per epoch (`notes/<id>.seed.json` is epoch
  0, `notes/<id>.seed.<n>.json` a checkpoint) and append-only state chunks per
  device: `notes/<id>.<device>-<seq>.json` in epoch 0,
  `notes/<id>.<device>-<seq>.<n>.json` in epoch `n`. A chunk is the Yjs delta
  since that device's previous chunk, so an edit uploads the edit; every 32
  chunks the device writes one full state and removes its older chunks.
  Every device writes only its own files, so Google Drive's lack of a
  conditional write cannot lose an update; the files are read and merged.
  `folders.json` and the front-matter `folder` remain for migration and as
  plain-text hints, but a client with workspace state ignores them. Dropbox:
  the app's App folder (`Apps/<app name>/`); Google Drive: a `Misstype`
  folder, scope `drive.file` (only files this app created).
- Body merge (`syncNotes`, tested by `tests/editor_sync_test.mjs` with two
  devices on an in-memory remote): `base` remembers each note's remote revision
  and a hash of the agreed body. One-sided changes and deletions go across; an
  edit beats a delete; a fresh empty note is not uploaded. The `.md` is also
  the existence marker and the export, so an older client that does not know
  about content CRDT can still edit it. If `folders.json` disappears after a
  pass (the folder was wiped), the next pass starts over and uploads instead
  of deleting local notes. Writes to Dropbox are conditional on the revision,
  so a lost race is retried next pass; body files on Drive can still lose a
  same-second write to the note (still in Drive's version history), while the
  CRDT files cannot.
- Document merge (`content.js`, `content-sync.js`, tested by
  `tests/editor_content_test.mjs`): each note has a Y.Doc bound to the
  ProseMirror editor with `y-prosemirror`; local state is a full record in
  `misstype-editor-crdt:<id>` plus a pending tail in
  `misstype-editor-crdt-tail:<id>`, and the Markdown cache above is rewritten
  from the merged document. A save writes only the pending tail (folded into
  the full record at 8 KB or when the tail outgrows it), not the note's whole
  history. The editor keeps ProseMirror history for undo; remote Yjs updates
  are marked `addToHistory: false`, and the decoder's pre-edit is a widget
  outside the document.
  A Y.Doc seeded independently from the same Markdown on two devices has
  different item histories and would concatenate on merge, so the first device
  to sync a note writes the canonical seed. Other devices adopt it when they
  have no local edits (or no local document), and a device that edited before
  seeing the seed keeps both texts exactly as before for one pass, then rebases
  the kept text onto the seed so later conflicts merge. Once two devices share
  a seed, both-sides-edited is merged (no duplicate, `report.merged` and a
  toast); `busy(id)` defers a merge while the note on screen is being composed
  or saved. A per-device dirty flag (not a delta-length test, which the Yjs
  delete set makes true forever) decides whether a pass uploads at all.
  The sync base keeps each content file's revision, bytes and state vector
  (`seen`), so a pass reads only files it has not applied: an idle pass reads
  no note content and writes nothing. A checkpoint (see Cost) writes a new
  seed epoch from the merged Markdown; a device whose body did not change
  adopts it silently, one with local edits keeps both texts for a pass and
  rebases. An old client's `.md`-only edit is taken into the local Y.Doc as a
  whole-document update, so the next edit can merge again.
- Workspace merge (`workspace.js`, tested by `tests/editor_workspace_test.mjs`):
  the folder list and each note's placement/order are Yjs maps, merged per
  field rather than as one JSON blob. A move on one device and a body edit on
  another therefore both survive; concurrent renames/moves are
  last-writer-wins per field. A folder delete is a tombstone, and a later
  rename can bring the folder back; notes are never deleted by the workspace —
  the body file decides existence, so edit-beats-delete still holds. A note
  whose folder is gone shows at the top level, never disappears. The first
  pass with no workspace file seeds the CRDT from the local index (after the
  legacy `folders.json` / front-matter merge), so enabling this does not need
  a migration tool. Each device uploads its full workspace state only when it
  changed; an idle pass writes nothing.
- Cost: Yjs and `y-prosemirror` add about 36 KB gzip to the editor chunks
  (editor 148.88 kB gzip, cloud/content 34.59 kB gzip in the production build).
  Workspace state holds only names, ids and order keys. Note CRDT state is
  stored next to the Markdown cache, so a note costs its Markdown plus the full
  CRDT record plus a pending tail of at most 8 KB in localStorage; on a
  storage-full device both writes fail the same way as before. Measured with
  `node tools/editor_sync_bench.mjs` (`--check` asserts the bounds; sizes are
  UTF-16/JSON bytes, not gzip):
  - one note, 1,000 edits of 10 characters (29.3 kB of text): the CRDT part of
    an edit's upload is ~0.1 kB (it was ~68 kB before delta chunks); the rest is
    the `.md` export, which is O(text) by design. An idle pass reads and writes
    no note content (it was 3 reads / 8 kB for one note, 104 reads for 100
    notes).
  - 100 notes, two devices: a settled pass reads no note content; a pass that
    pulls one edit reads the changed `.md` and its one new chunk.
  - 1 kB note rewritten 2,000 times (the tombstone case): 44 kB of history
    (45× the text) without a checkpoint; the next idle pass checkpoints to
    ~2.9 kB (2.9× text, including the epoch-0 seed kept for older clients).
  A checkpoint runs only on a fully merged, idle note whose history exceeds 8×
  its text (minimum 16 KB). It writes a new seed epoch, drops the older chunks,
  and keeps the epoch-0 seed; a concurrent edit that the checkpointing device
  had not listed can still cost one duplicate pass. A device that loses
  localStorage starts a new chunk sequence (old files merge harmlessly) and a
  deleted note removes its seed/state files. A client still on the pre-workspace
  build keeps reading the stale `folders.json`/`.md` and can edit the body; its
  edit is imported as a whole-document CRDT update, but it will not see
  concurrent merges. A pre-epoch client reads epoch 0 but ignores the new seed
  and chunks after a checkpoint; its `.md` edits still reach current clients.
  The `.md` front-matter `folder` can lag behind a move until that note's next
  body edit. There is no relay, presence or realtime editing: both text and
  organization converge on the next pass.
- When: 4 s after the last save (any change in `notes.js` fires `onChange`),
  on load, when the tab becomes visible or the network comes back, and every
  2 minutes while visible; not while composing. Tabs take turns through Web
  Locks. The status strip shows the state and syncs on click; the palette has
  立即同步; Settings → 雲端同步 connects, syncs and disconnects (disconnecting
  deletes nothing on either side). The strip stays one line on a phone: spacing
  tightens, the button keeps the state but drops the time (under 480px; the
  full time is in Settings and the button's title), and a long status message
  ends with an ellipsis instead of wrapping. Checked in Chromium at 320, 360,
  375, 390, 414 and 430px with the offline badge shown: one 36px row.
- Sign-in (`cloud.js`, `oauth.html`): a popup (full-page redirect if it is
  blocked) whose callback page passes the answer back through localStorage.
  Dropbox uses the code flow with PKCE and a refresh token, so it keeps
  working. Google gives a browser-only app no refresh token: after about an
  hour the strip says 需要重新登入 and sync waits for a click (signing in again
  to the same account keeps the sync state; another account starts over and
  merges). Tokens live in localStorage next to the notes.
- Setup (maintainer): a Dropbox app with App folder access and the scopes
  `files.content.read`, `files.content.write`, `files.metadata.read`; a Google
  OAuth client of type Web application with the Drive API enabled. Register
  every origin's `…/editor/oauth.html` as redirect URI (Pages and Vercel are
  different origins; `http://localhost:5173/editor/oauth.html` for `npm run dev`). The app key and client ID are public;
  they reach the build as `VITE_DROPBOX_APP_KEY` / `VITE_GOOGLE_CLIENT_ID`
  (Pages: repository variables `DROPBOX_APP_KEY`, `GOOGLE_CLIENT_ID`; Vercel:
  project environment variables). A provider without one is not offered.
- Checked: the body, content and workspace merge tests (including delta
  chunks, compaction, a checkpoint, a local edit across a checkpoint, and a
  legacy full-state file), `node tools/editor_sync_bench.mjs --check`, a
  production build, and Chromium runs of the editor: typing (both
  `Input.insertText` and the real Zhuyin key sequence `su3cl3` → 你好 with
  Enter) updates the Markdown cache and the Y.Doc, reload restores the text,
  Ctrl+Z undoes it, and switching notes keeps each note's text and CRDT state.
  Not yet run against the real Dropbox or Drive APIs (no app registered yet),
  nor in an installed iOS home-screen app, where the sign-in popup may open
  outside the app.

## Commands and keys

Command palette: `Mod-Shift-P` (or F1, or the 指令 button). Also
`Mod-Shift-C` copy Markdown, `Mod-Shift-X` copy plain text, `Mod-Shift-K` clear
(undoable), 立即同步 (palette only), `Mod-S` download `.md`, `Mod-Shift-E` toggle 中/英 (a Shift tap
too), `Mod-,` settings. The 中/英 mode flashes beside the cursor when it changes, including a Shift tap or backtick that opens or closes an English run inside a Chinese composition (as on desktop) and is shown in the status strip; there is no header button for it. `Ctrl-J/K` stay with the decoder.

## iOS 26 Safari chrome

Safari 26 draws the page edge to edge under translucent bars and tints them
from the page background or a sticky/fixed element at the edge (`theme-color`
is unreliable there). So `editor.css` keeps `html`, `body`, the
header/toolbar and the status strip all `--paper` and puts the safe-area insets
on those bars instead of the body.
The window never scrolls. The body is `position: fixed`, pinned to the visual
viewport (`--vv-h` / `--vv-top`, set from `visualViewport` in `editor.js`,
skipped while pinch-zoomed), and only the document (`main.pg`) scrolls between
the header and the status strip, with a small fixed caret margin. Before, the
window scrolled under sticky bars: the page ran a keyboard's height (or a 40vh
pad) past the end of the note, in iPhone landscape the margins kept clear of
the bars added up to more than the screen so every key scrolled, and with only
Safari's form bar showing the status strip ended up mid-screen. The cost is
that Safari's bars no longer collapse on scroll. The bottom pad after the note
is 30vh with a mouse and 3em on touch screens.
Safari also scrolls the page when a dialog's field takes focus (raising the
system keyboard) and when focus returns to the editor; `editor.js` remembers
the scroll position while no dialog is open and restores it as any dialog
closes, before a palette command runs. Text fields and selects in dialogs are
16px on touch screens, since iOS zooms into smaller ones and stays zoomed.
Every sheet (settings, dictionary, learning, about) is capped to the visible
viewport and scrolls inside it, with the safe-area insets as margins; on
screens up to 480px a dropdown moves under its label and controls may shrink.
A `<select>` is as wide as its longest option, and Settings' 螢幕鍵盤 sentence
used to widen the whole sheet past a phone screen, which made the card scroll
sideways and clipped its right column (checked at 320/375/390/414px).
Checked only with Chromium's iPad emulation (no safe-area insets there).

## About

An About dialog (status strip, or the palette) says what the page is for: the same
IME inside a web page, for devices that cannot install a custom one, with links to
the native macOS and Linux versions and the privacy note. It also shows the build
it is running (the first seven characters of the commit, or a local timestamp):
compare it between Safari and an installed app to tell whether one is still on an
old service-worker cache.

## Known limits

- In Chinese mode the decoder owns `-`, `#`, `*`, backtick and digits, so
  Markdown shortcuts (`# `, `- `, `**bold**`) only trigger in English mode;
  the toolbar and palette work in either.
- `---`, `***` or `___` alone in a paragraph becomes a divider (English mode,
  like the other shortcuts); the palette's 分隔線 inserts one in either mode.
- The Markdown schema has no strikethrough, tables or task lists.
- Two devices that edit the same note before ever sharing a content seed keep
  both texts for one pass (the old duplicate behavior), then rebase the kept
  text onto the seed. This is the upgrade path; later conflicts merge.
- `folders.json` is no longer updated once any device has workspace state; an
  older build keeps seeing the last folder list it wrote. An older build can
  still edit the `.md` body, but it cannot participate in CRDT merging.
- Content state is compacted per device (every 32 chunks) and per note (a
  checkpoint at 8× the text, minimum 16 KB), but a checkpoint keeps the
  epoch-0 seed for older clients, so a checkpointed note still carries one
  stale seed. An idle pass reads no content; a pass still lists the whole
  remote prefix, and a note's `.md` body is uploaded whenever it changes.
- A checkpoint can race an edit that lands between its list and its new seed;
  that device keeps both texts for one pass (a duplicate), then rebases.
- The on-screen keyboard has no one-shot Shift (tap Shift then a letter) or number/symbol layers; Shift is hold-only because a tap is 中/英. With no number row, digits and symbols are the top row's English-mode (or Shift) caps.
- Not tried on a real iPad or in an installed home-screen app; the offline
  path is verified with Chromium only.
