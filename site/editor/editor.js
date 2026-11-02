import { EditorState, Plugin, TextSelection } from "prosemirror-state";
import { Decoration, DecorationSet, EditorView } from "prosemirror-view";
import { Slice } from "prosemirror-model";
import { baseKeymap } from "prosemirror-commands";
import { history, redo, undo } from "prosemirror-history";
import { keymap } from "prosemirror-keymap";
import { dropCursor } from "prosemirror-dropcursor";
import "prosemirror-view/style/prosemirror.css";
import MisstypeWasm from "../../packages/misstype-wasm/src/index.js";
import "../playground.css";
import "./editor.css";
import { actions, editingKeys, horizontalKeys } from "./actions.js";
import { CandidatePanel } from "./candidates.js";
import { chord, isApple, matches, modifierBits } from "./keys.js";
import { initProseMirrorDoc, ySyncPlugin } from "y-prosemirror";
import { parseMarkdown, schema, toMarkdown, wordCount } from "./model.js";
import { createContent } from "./content.js";
import { createDictionary } from "./dictionary.js";
import { createLearning } from "./learning.js";
import { tick } from "./haptics.js";
import { VirtualKeyboard, fromHardwareKeyboard, systemKeyboardSuppressed, virtualKeyboardVisible } from "./keyboard.js";
import { Palette } from "./palette.js";
import { preeditKey, preeditPlugin, setPreedit } from "./preedit.js";
import { registerServiceWorker } from "./pwa.js";
import { markdownRules } from "./rules.js";
import { IME_KEYS, loadSettings, saveSettings } from "./settings.js";
import { createNotes, UNTITLED } from "./notes.js";
import { createCloud, PROVIDERS, RESULT_KEY } from "./cloud.js";
import { createWorkspace } from "./workspace.js";
import { Sidebar } from "./sidebar.js";
import { zenPlugin } from "./zen.js";

const $ = (sel) => document.querySelector(sel);

const settings = loadSettings();
const app = $(".pg");
const toastEl = $("#toast");
const modeLabel = $("#mode-label");
const modeFlash = $("#mode-flash");
const countEl = $("#count");
const docTitleEl = $("#doc-title");
// Build that the page is actually running. Compare Safari with the installed
// app when one of them looks stale; Vite replaces this at build time.
const buildLabelEl = $("#build-label");
if (buildLabelEl) buildLabelEl.textContent = typeof __MISSTYPE_BUILD__ === "string" ? __MISSTYPE_BUILD__ : "dev";

let ime = null;
let imeState = null;
let nativeImeKeys = 0;

// ---------------------------------------------------------------- document

let workspace;
const notes = createNotes(undefined, {
  onChange: () => scheduleSync(),
  onWorkspace: (op) => workspace?.applyLocal(op),
});
let currentId = notes.load().current;
// Editor states of notes opened this visit, so each keeps its own undo history.
const states = new Map();

// The CRDT document for each note. Markdown stays the export/cache; this is
// what merges concurrent text edits.
const content = createContent({
  notes,
  onUpdate: (id) => {
    if (id === currentId) {
      scheduleSave();
      updateCount();
    }
  },
});

// Organization state (folders, note placement and order) as a local CRDT;
// sync.js writes it to this device's own static file in the cloud folder.
workspace = createWorkspace({ onChange: () => scheduleSync() });

// Cloud sync (cloud.js, sync.js): off until an account is connected in Settings.
const cloud = createCloud({
  notes,
  workspace,
  content,
  // The note on screen while it has unsaved typing: remote text must not replace it.
  busy: (id) => id === currentId && Boolean(saveTimer || imeState?.preedit),
  onChange: renderSync,
});
let syncTimer = 0;

// The first run has no workspace state: seed it from the local index, then
// apply it back so old (order-less) indexes get their order keys once.
workspace.ensure(notes.workspaceState());
workspace.project(notes);

let saveTimer = 0;
function scheduleSave() {
  clearTimeout(saveTimer);
  saveTimer = setTimeout(saveNow, 400);
}

function saveNow() {
  if (!saveTimer) return;
  clearTimeout(saveTimer);
  saveTimer = 0;
  if (notes.write(currentId, toMarkdown(view.state.doc))) {
    sidebar.render();
    renderDocTitle();
  }
  content.persist(currentId);
}

const placeholder = new Plugin({
  props: {
    decorations({ doc }) {
      const empty = doc.childCount === 1 && doc.firstChild.isTextblock && doc.firstChild.content.size === 0;
      return empty
        ? DecorationSet.create(doc, [Decoration.node(0, doc.firstChild.nodeSize, {
          class: "is-empty",
          "data-placeholder": "開始打字⋯ 打 # 加空白是標題，- 加空白是清單。",
        })])
        : null;
    },
  },
});

const createState = (id) => {
  const { fragment } = content.open(id);
  const { doc, mapping } = initProseMirrorDoc(fragment, schema);
  return EditorState.create({
    doc,
    plugins: [
      ySyncPlugin(fragment, { mapping }),
      markdownRules,
      history(),
      keymap({ ...editingKeys, ...horizontalKeys, "Mod-z": undo, "Mod-y": redo, "Shift-Mod-z": redo }),
      keymap(baseKeymap),
      dropCursor(),
      preeditPlugin,
      placeholder,
      zenPlugin,
    ],
  });
};

function createView() {
  return new EditorView($("#editor"), {
    state: createState(currentId),
    // Pasted plain text is read as Markdown, so notes from other editors keep their structure.
    clipboardTextParser: (text, $context, plain) => {
      if (plain) return undefined;
      return new Slice(parseMarkdown(text).content, 0, 0);
    },
    dispatchTransaction(tr) {
      view.updateState(view.state.apply(tr));
      if (tr.docChanged) {
        scheduleSave();
        updateCount();
      }
      updateToolbar();
    },
  });
}

const view = createView();
const updateCount = () => { countEl.textContent = `${wordCount(view.state.doc).total} 字`; };

function show(id) {
  currentId = id;
  view.updateState(states.get(id) ?? createState(id));
  app.scrollTop = 0;
  updateCount();
  updateToolbar();
  renderDocTitle();
}

/** The title in the header is the note's first line, the same one the sidebar shows. */
function renderDocTitle() {
  const note = notes.load().notes.find((n) => n.id === currentId);
  const title = note?.title || UNTITLED;
  const label = `切換筆記：${title}`;
  docTitleEl.textContent = title;
  docTitleEl.setAttribute("aria-label", label);
  docTitleEl.title = `${label} (${chord("Mod-p")})`;
  document.title = `${title} · 隨打注音`;
}

/** Saves the note on screen and puts another one in its place. */
function openNote(id) {
  flush();
  if (id !== currentId) {
    saveNow();
    states.set(currentId, view.state);
    show(id);
  }
  notes.setCurrent(id);
  sidebar.render();
  sidebar.reveal();
  if (narrowSidebar.matches) setSidebar(false);
  view.focus();
}

const currentFolder = () => notes.load().notes.find((n) => n.id === currentId)?.folder ?? null;

function newNote(folder = currentFolder(), markdown = "") {
  flush();
  saveNow();
  states.set(currentId, view.state);
  show(notes.create(folder, markdown));
  sidebar.render();
  sidebar.reveal();
  if (narrowSidebar.matches) setSidebar(false);
  view.focus();
}

/** Deletes a note (asking first unless it is empty) and opens a neighbour if it was on screen. */
function deleteNote(id) {
  flush();
  const note = notes.load().notes.find((n) => n.id === id);
  if (!note) return;
  const current = id === currentId;
  const empty = !(current ? toMarkdown(view.state.doc) : notes.read(id)).trim();
  const title = note.title || UNTITLED;
  if (!empty && !confirm(`刪除「${title}」？刪除後無法復原。`)) return;
  if (current) { clearTimeout(saveTimer); saveTimer = 0; }
  states.delete(id);
  content.forget(id);
  const next = notes.delete(id);
  if (current) show(next);
  sidebar.render();
  if (!empty) toast(`已刪除「${title}」`);
  if (current) view.focus();
}

// Only the document scrolls, between the header and the status strip (editor.css),
// so the caret needs just a little room when ProseMirror scrolls it into view.
const caretMargin = { top: 12, bottom: 24, left: 8, right: 8 };
view.setProps({ scrollMargin: caretMargin, scrollThreshold: caretMargin });

// The page is pinned to the visible part of the screen: on iOS the system
// keyboard and Safari's form bar shrink the visual viewport but not 100dvh,
// and the layout viewport can be panned under them. Skipped while pinch-zoomed.
function fitViewport() {
  const vv = window.visualViewport;
  if (!vv || Math.abs(vv.scale - 1) > 0.01) return;
  document.documentElement.style.setProperty("--vv-h", `${Math.round(vv.height)}px`);
  document.documentElement.style.setProperty("--vv-top", `${Math.round(vv.offsetTop)}px`);
}
fitViewport();
visualViewport?.addEventListener("resize", fitViewport);
visualViewport?.addEventListener("scroll", fitViewport);

function runAction(id) {
  actions[id].run(view.state, view.dispatch, view);
  view.focus();
}

// --------------------------------------------------------------------- IME

// On the body, not in the scrolling .pg: on iOS the panel's z-index does not
// reach past the scroller, so the header and status strip drew over it.
const panel = new CandidatePanel(document.body, {
  onPick: (index) => { ime?.pick(index); sync(); view.focus(); },
  onPage: (code) => { ime?.key(code, code, 0, 0); sync(); view.focus(); },
  onDismiss: dismissKeyboard,
  bottomInset: () => vkHeight(),
});

function caretRect() {
  const caret = view.dom.querySelector(".pg-composition-caret") || view.dom.querySelector(".pg-preedit");
  if (caret) return caret.getBoundingClientRect();
  try {
    const { top, bottom, left } = view.coordsAtPos(view.state.selection.head);
    return { top, bottom, left, right: left };
  } catch {
    return view.dom.getBoundingClientRect();
  }
}

/** Moves finished text into the document and redraws the pre-edit and candidates. */
function sync(fromKey = false) {
  if (!ime) return;
  const text = ime.takeCommitted();
  imeState = ime.state();
  const preedit = imeState.preedit ? imeState : null;
  // Only when something changed: most keys outside a composition (arrows,
  // shortcuts) leave the decoder idle and need no transaction.
  if (text || preedit || preeditKey.getState(view.state)) {
    let tr = view.state.tr;
    if (text) tr = tr.insertText(text).scrollIntoView();
    view.dispatch(setPreedit(tr, preedit));
  }
  dictionary.persistIfChanged(ime);
  learning.persistIfChanged(ime);
  panel.render(imeState, caretRect());
  const english = imeState.english;
  modeLabel.textContent = english || imeState.latinActive ? "英" : "中";
  vk.setEnglish(Boolean(english || imeState.latinActive));
  // As on desktop: a Shift tap or backtick that opens or closes an English run
  // inside a Chinese composition (latinToggled) and a mode change both flash.
  // The flags describe the last key, so only a key event may read them.
  if (fromKey && imeState.latinToggled) flashMode(imeState.latinActive);
  if (fromKey && imeState.modeChanged) flashMode(english);
}

/** Settles an unfinished composition so the editor can act on real text. */
function flush() {
  if (ime && imeState?.preedit && ime.commit()) sync();
}

/** Like the desktop IMEs: a small 中 / 英 appears beside the cursor when the mode changes. */
function flashMode(english) {
  const rect = caretRect();
  modeFlash.textContent = english ? "英" : "中";
  modeFlash.classList.toggle("english", english);
  modeFlash.style.left = `${Math.round(rect.left + 6)}px`;
  modeFlash.style.top = `${Math.round(rect.top - 26)}px`;
  modeFlash.classList.remove("show");
  void modeFlash.offsetWidth; // restart the fade
  modeFlash.classList.add("show");
}

function keyDown(e) {
  if (!ime) return;
  // A system IME took the key first; the decoder can't help while it is on.
  if (e.isComposing || e.keyCode === 229) {
    nativeImeKeys += 1;
    if (nativeImeKeys === 2) toast("系統輸入法開著了，請切到英文鍵盤再打");
    return;
  }
  nativeImeKeys = 0;
  // Document shortcuts belong to the editor; settle the composition first.
  // Control+J/K stay with the decoder.
  const decoderCtrl = e.ctrlKey && !e.metaKey && ["KeyJ", "KeyK"].includes(e.code);
  if (e.metaKey || (e.ctrlKey && !decoderCtrl) || e.code === "Home" || e.code === "End") {
    flush();
    return;
  }
  if (ime.key(e.code, e.key, modifierBits(e), 0)) {
    e.preventDefault();
    e.stopPropagation();
  }
  sync(true);
}

function keyUp(e) {
  if (!ime || (e.code !== "ShiftLeft" && e.code !== "ShiftRight")) return;
  if (ime.key(e.code, e.key, modifierBits(e), 1)) e.preventDefault();
  sync(true);
}

// ------------------------------------------------------- virtual keyboard

// Touch devices without a keyboard get an on-screen Zhuyin keyboard. Its keys are
// replayed as ordinary KeyboardEvents on the editor, so the decoder, settings
// and ProseMirror's keymaps see exactly what a hardware keyboard would send.
const vkEl = $("#vk");
vkEl.dataset.platform = /Android/i.test(navigator.userAgent) ? "android" : "ios";
// Auto only claims a touch-only device, so a touchscreen laptop with a mouse
// keeps the keyboard away on load. The status switch is the manual override.
const touchOnly = matchMedia("(pointer: coarse) and (hover: none)");
const vkButton = $("#vk-btn");
// Remembered across visits: an iPad with a keyboard should not flash ours on every load.
// ":2": the first key was also set by system-keyboard typing in text fields; drop those.
const HW_KEYBOARD_KEY = "misstype-hardware-keyboard:2";
try { localStorage.removeItem("misstype-hardware-keyboard"); } catch { /* private mode */ }
const storedHardwareKeyboard = () => {
  try { return localStorage.getItem(HW_KEYBOARD_KEY) === "1"; } catch { return false; }
};
const rememberHardwareKeyboard = (seen) => {
  try { seen ? localStorage.setItem(HW_KEYBOARD_KEY, "1") : localStorage.removeItem(HW_KEYBOARD_KEY); } catch { /* private mode */ }
};
let hardwareKeyboardSeen = storedHardwareKeyboard();
// Dismissed with the chevron: hidden until the editor takes focus again, as the system keyboard does.
let vkDismissed = false;

const vkHeight = () => (vkEl.hidden ? 0 : vkEl.offsetHeight);

function applyVirtualKeyboard() {
  const on = virtualKeyboardVisible(settings.virtualKeyboard, touchOnly.matches, hardwareKeyboardSeen, vkDismissed);
  vkEl.hidden = !on;
  document.body.classList.toggle("vk-on", on);
  panel.setDocked(on);
  if (imeState) panel.render(imeState, caretRect());
  // Without this the system keyboard would pop up over ours, dismissed or not.
  // A hardware keyboard keeps the decoder in charge even when the on-screen
  // keyboard is switched off: otherwise the system IME takes the letters back
  // and English mode in the page has no effect.
  view.setProps({ attributes: systemKeyboardSuppressed(settings.virtualKeyboard, touchOnly.matches, hardwareKeyboardSeen) ? { inputmode: "none" } : {} });
  document.documentElement.style.setProperty("--vk-h", `${vkHeight()}px`);
  vkButton.setAttribute("aria-pressed", String(on));
  vkButton.title = on ? "隱藏螢幕鍵盤" : "顯示螢幕鍵盤";
}

/** Shows or hides the keyboard by writing the same setting the Settings sheet edits. */
function toggleVirtualKeyboard() {
  flush();
  if (!vkEl.hidden) {
    setSetting("virtualKeyboard", "off");
    // The button had focus; give it back so typing continues.
    view.focus();
    return;
  }
  // A chevron dismissal outranks the setting; showing it manually clears that.
  vkDismissed = false;
  setSetting("virtualKeyboard", "on");
  view.focus();
}

function dismissKeyboard() {
  flush();
  vkDismissed = true;
  view.dom.blur();
  applyVirtualKeyboard();
}

function sendKey(type, code, key, shift) {
  const e = new KeyboardEvent(type, { code, key, shiftKey: shift, bubbles: true, cancelable: true });
  view.dom.dispatchEvent(e);
  return e;
}

/** Backspace's browser default: the selection, else the character before the caret. */
function deleteBackward() {
  const { selection } = view.state;
  if (!selection.empty) {
    view.dispatch(view.state.tr.deleteSelection().scrollIntoView());
    return;
  }
  const { $from } = selection;
  if ($from.parentOffset === 0) return;
  const before = $from.parent.textBetween(Math.max(0, $from.parentOffset - 16), $from.parentOffset, "\n", "\ufffc");
  const last = Array.from(before).pop() || "";
  if (!last) return;
  view.dispatch(view.state.tr.delete($from.pos - last.length, $from.pos).scrollIntoView());
}

// Touching a key can blur the editor (iOS ignores preventDefault for focus), and
// the blur handler below settles the composition, which would commit the
// pre-edit. Keys of our own keyboard are not "leaving the editor".
let vkTouchUntil = 0;
vkEl.addEventListener("pointerdown", () => { vkTouchUntil = performance.now() + 600; }, true);

const vk = new VirtualKeyboard(vkEl, {
  shift(down) {
    if (down && settings.haptics) tick();
    sendKey(down ? "keydown" : "keyup", "ShiftLeft", "Shift", down);
    if (!view.hasFocus()) view.focus();
  },
  press(code, key, shift) {
    if (settings.haptics) tick();
    const e = sendKey("keydown", code, key, shift);
    if (!e.defaultPrevented) {
      // Neither the decoder nor a keymap took it. A hardware key would now do
      // its browser default, which a synthetic event does not: do it here.
      const { from, to } = view.state.selection;
      if (key.length === 1) {
        const insert = () => view.state.tr.insertText(key, from, to);
        if (!view.someProp("handleTextInput", (f) => f(view, from, to, key, insert))) view.dispatch(insert().scrollIntoView());
      } else if (code === "Backspace") {
        deleteBackward();
      }
    }
    // Tapping a key must never leave the editor (and the caret) unfocused.
    if (!view.hasFocus()) view.focus();
  },
});

// A real keyboard showed up (iPad with a Magic Keyboard, say): give the screen back.
document.addEventListener("keydown", (e) => {
  if (hardwareKeyboardSeen || !fromHardwareKeyboard(e, view.dom)) return;
  hardwareKeyboardSeen = true;
  rememberHardwareKeyboard(true);
  // Even with the on-screen keyboard switched off: a hardware key must keep
  // the system IME away, or the letters never reach the decoder.
  applyVirtualKeyboard();
}, true);
touchOnly.addEventListener("change", applyVirtualKeyboard);
new ResizeObserver(() => {
  document.documentElement.style.setProperty("--vk-h", `${vkHeight()}px`);
}).observe(vkEl);

function applyImeSettings() {
  if (!ime) return;
  for (const key of IME_KEYS) ime.setSetting(key, settings[key]);
  sync();
}

function applyAppearance() {
  panel.setLayout(settings.candidateLayout);
  panel.setTheme(settings.candidateTheme);
  app.dataset.theme = settings.candidateTheme;
  document.documentElement.style.setProperty("--editor-size", `${settings.fontSize}px`);
  app.dataset.wrap = settings.wrap;
  applyVirtualKeyboard();
}

async function loadIme() {
  const assets = new URL("../", document.baseURI);
  const at = (name) => new URL(name, assets).href;
  try {
    ime = await MisstypeWasm.load({
      wasmUrl: at("misstype.wasm"),
      lexiconUrl: at("lexicon.tsv"),
      tonelessUrl: at("toneless.tsv"),
      englishUrl: at("english.tsv"),
      homophoneUrl: at("homophone.bin"),
    });
    dictionary.restore(ime);
    learning.restore(ime);
    applyImeSettings();
    document.body.classList.add("ime-ready");
    $("#status").textContent = "隨打注音已就緒";
  } catch (err) {
    console.error(err);
    $("#status").textContent = "注音載入失敗，目前只能打英文";
  }
}

// ---------------------------------------------------------------- commands

function toast(message) {
  toastEl.textContent = message;
  toastEl.classList.add("show");
  clearTimeout(toast.timer);
  toast.timer = setTimeout(() => toastEl.classList.remove("show"), 2200);
}

async function copyText(text, done) {
  try {
    await navigator.clipboard.writeText(text);
  } catch {
    const area = Object.assign(document.createElement("textarea"), { value: text });
    area.style.cssText = "position:fixed;opacity:0";
    document.body.append(area);
    area.select();
    document.execCommand("copy");
    area.remove();
  }
  toast(done);
}

const plainText = () => view.state.doc.textBetween(0, view.state.doc.content.size, "\n\n", "\n");

function download() {
  const url = URL.createObjectURL(new Blob([toMarkdown(view.state.doc)], { type: "text/markdown;charset=utf-8" }));
  const name = (notes.load().notes.find((n) => n.id === currentId)?.title || "note").replace(/[\\/:*?"<>|…]+/g, " ").trim().slice(0, 40) || "note";
  const a = Object.assign(document.createElement("a"), { href: url, download: `${name}.md` });
  document.body.append(a);
  a.click();
  a.remove();
  setTimeout(() => URL.revokeObjectURL(url), 1000);
}

/** Opens a Markdown file as a new note. */
function importFile() {
  const input = Object.assign(document.createElement("input"), { type: "file", accept: ".md,.markdown,.txt,text/markdown,text/plain" });
  input.addEventListener("change", async () => {
    const file = input.files?.[0];
    if (!file) return;
    newNote(currentFolder(), await file.text());
    toast(`已匯入 ${file.name}`);
  });
  input.click();
}

function clearAll() {
  const tr = view.state.tr.delete(0, view.state.doc.content.size);
  view.dispatch(tr.setSelection(TextSelection.atStart(tr.doc)));
  toast(`已清空（${chord("Mod-z")} 可復原）`);
}

function toggleMode() {
  if (!ime) return;
  ime.toggleEnglish();
  sync();
  flashMode(imeState.english);
  view.focus();
}

function setSetting(key, value) {
  settings[key] = value;
  saveSettings(settings);
  // Choosing "auto" again starts keyboard detection over.
  if (key === "virtualKeyboard" && value === "auto") {
    hardwareKeyboardSeen = false;
    rememberHardwareKeyboard(false);
  }
  applyAppearance();
  if (IME_KEYS.includes(key)) applyImeSettings();
}

const dictionary = createDictionary({ getIme: () => ime, toast, onClose: () => view.focus() });

const learning = createLearning({ getIme: () => ime, toast, onClose: () => view.focus() });

const act = (id) => () => runAction(id);

const commands = [
  { id: "palette", title: "指令選單", chord: chord("Mod-Shift-p"), combo: "Mod-Shift-p", run: () => palette.open() },
  { id: "copy-md", title: "複製為 Markdown", keywords: "copy markdown 複製", combo: "Mod-Shift-c", chord: chord("Mod-Shift-c"),
    run: () => copyText(toMarkdown(view.state.doc), "已複製 Markdown") },
  { id: "copy-text", title: "複製為純文字", keywords: "copy plain text 複製", combo: "Mod-Shift-x", chord: chord("Mod-Shift-x"),
    run: () => copyText(plainText(), "已複製純文字") },
  { id: "switch-note", title: "切換筆記⋯", keywords: "switch open go to note quick 開啟 跳到 筆記", combo: "Mod-p", chord: chord("Mod-p"),
    run: () => openSwitcher() },
  { id: "new-note", title: "新增筆記", keywords: "new note create 新筆記 建立", combo: "Mod-Alt-n", chord: chord("Mod-Alt-n"),
    run: () => newNote() },
  { id: "sidebar", title: "顯示／隱藏筆記列表", keywords: "sidebar notes list folders tree 側欄 資料夾", combo: "Mod-\\", chord: chord("Mod-\\"),
    run: () => setSidebar(!sidebarOpen()) },
  { id: "zen", title: "專注模式", keywords: "zen focus mode distraction free hide 禪 專心", combo: "Mod-Shift-f", chord: chord("Mod-Shift-f"),
    run: () => setZen(!document.body.classList.contains("zen")) },
  { id: "delete-note", title: "刪除這篇筆記", keywords: "delete remove note 刪除 筆記", run: () => deleteNote(currentId) },
  { id: "new-folder", title: "新增資料夾", keywords: "folder new 資料夾", run: () => { setSidebar(true); sidebar.newFolder(); } },
  { id: "para", title: "建立 PARA 資料夾", keywords: "para projects areas resources archives folders 資料夾", run: () => { setSidebar(true); sidebar.addPara(); } },
  { id: "clear", title: "清空內容", keywords: "clear delete empty 清除", combo: "Mod-Shift-k", chord: chord("Mod-Shift-k"), run: clearAll },
  { id: "download", title: "下載 .md 檔", keywords: "download save export 儲存", combo: "Mod-s", chord: chord("Mod-s"), run: download },
  { id: "import", title: "匯入 Markdown 檔為新筆記", keywords: "import open file 開啟", combo: "Mod-o", chord: chord("Mod-o"), run: importFile },
  { id: "mode", title: "切換中／英", keywords: "english chinese mode 中英", combo: "Mod-Shift-e", chord: chord("Mod-Shift-e") + " · 輕按 Shift", run: toggleMode },
  { id: "dictionary", title: "我的詞庫", keywords: "dictionary words phrases user 詞庫 詞彙", combo: "Mod-Shift-d", chord: chord("Mod-Shift-d"), run: () => dictionary.open() },
  { id: "learning", title: "學習資料", keywords: "learning learned phrases slips forget 學習 學到的詞 打錯", run: () => learning.open() },
  { id: "sync", title: "立即同步", keywords: "sync cloud dropbox google drive backup 同步 雲端 備份",
    run: () => (cloud.provider && !cloud.status.needsSignIn ? runSync() : openSettings()) },
  { id: "about", title: "關於", keywords: "about info help 說明 介紹", run: () => openAbout() },
  { id: "settings", title: "設定", keywords: "settings options preferences 選項", combo: "Mod-,", chord: chord("Mod-,"), run: () => openSettings() },
  { id: "keyboard", title: "顯示／隱藏螢幕鍵盤", keywords: "keyboard virtual on-screen 螢幕鍵盤", run: toggleVirtualKeyboard },
  { id: "layout", title: "候選窗：直式／橫式", keywords: "candidate layout vertical horizontal",
    run: () => setSetting("candidateLayout", settings.candidateLayout === "vertical" ? "horizontal" : "vertical") },
  { id: "theme", title: "切換淺色／深色", keywords: "theme dark light 主題", run: () => $(".theme-toggle").click() },
  { id: "h1", title: "標題 1", keywords: "heading", run: act("h1") },
  { id: "h2", title: "標題 2", keywords: "heading", run: act("h2") },
  { id: "h3", title: "標題 3", keywords: "heading", run: act("h3") },
  { id: "p", title: "一般段落", keywords: "paragraph", run: act("paragraph") },
  { id: "ul", title: "項目清單", keywords: "bullet list", run: act("bulletList") },
  { id: "ol", title: "編號清單", keywords: "ordered numbered list", run: act("orderedList") },
  { id: "quote", title: "引用", keywords: "blockquote", run: act("quote") },
  { id: "code", title: "程式碼區塊", keywords: "code block", run: act("codeBlock") },
  { id: "hr", title: "分隔線", keywords: "divider horizontal rule hr separator ---", run: act("divider") },
  { id: "bold", title: "粗體", keywords: "bold strong", chord: chord("Mod-b"), run: act("bold") },
  { id: "italic", title: "斜體", keywords: "italic emphasis", chord: chord("Mod-i"), run: act("italic") },
  { id: "inline-code", title: "行內程式碼", keywords: "code", chord: chord("Mod-`"), run: act("code") },
  { id: "undo", title: "復原", keywords: "undo", chord: chord("Mod-z"), run: () => { undo(view.state, view.dispatch); view.focus(); } },
  { id: "redo", title: "重做", keywords: "redo", chord: chord(isApple ? "Mod-Shift-z" : "Mod-y"), run: () => { redo(view.state, view.dispatch); view.focus(); } },
];

const palette = new Palette(() => commands);

/** The palette over the notes: most recently edited first, the open one last; matches title and folder. */
function openSwitcher() {
  saveNow();
  const index = notes.load();
  const folderName = new Map(index.folders.map((f) => [f.id, f.name]));
  const items = [...index.notes]
    .sort((a, b) => (a.id === currentId) - (b.id === currentId) || b.updated - a.updated)
    .map((note) => {
      const folder = folderName.get(note.folder) ?? "";
      return {
        id: `note:${note.id}`, title: note.title || UNTITLED, keywords: folder,
        hint: note.id === currentId ? `${folder ? `${folder} · ` : ""}目前` : folder,
        run: () => openNote(note.id),
      };
    });
  palette.open({ items, placeholder: "搜尋筆記標題或資料夾⋯", empty: "沒有符合的筆記" });
}
palette.onClose = () => view.focus();

// A dialog's text field (and the system keyboard it raises) and the editor
// taking focus back both make Safari scroll the page; a long note ended up at
// its top. Remember where the note was before a dialog opened and put it back
// as the dialog closes, before any command run from it scrolls on purpose.
const scrollers = () => [document.scrollingElement, app];
let scrollSpot = scrollers().map((el) => el.scrollTop);
addEventListener("scroll", () => {
  if (!document.querySelector("dialog[open]")) scrollSpot = scrollers().map((el) => el.scrollTop);
}, { capture: true, passive: true });
// Capture: runs before each dialog's own close handler.
document.addEventListener("close", (e) => {
  if (e.target instanceof HTMLDialogElement) scrollers().forEach((el, i) => { el.scrollTop = scrollSpot[i]; });
}, true);

document.addEventListener("keydown", (e) => {
  if (palette.isOpen || settingsDialog.open || aboutDialog.open || dictionary.isOpen || learning.isOpen || e.isComposing) return;
  const command = commands.find((c) => c.combo && matches(e, c.combo))
    || (e.key === "F1" && commands[0]);
  if (!command) return;
  e.preventDefault();
  e.stopPropagation();
  flush();
  command.run();
}, true);

// ----------------------------------------------------------------- toolbar

const toolbar = $("#toolbar");

function updateToolbar() {
  for (const button of toolbar.querySelectorAll("[data-action]")) {
    const action = actions[button.dataset.action];
    const on = action.active?.(view.state) ?? false;
    button.classList.toggle("on", on);
    button.setAttribute("aria-pressed", String(on));
  }
  const undoable = undo(view.state);
  const redoable = redo(view.state);
  toolbar.querySelector('[data-command="undo"]').disabled = !undoable;
  toolbar.querySelector('[data-command="redo"]').disabled = !redoable;
}

// Buttons must not take focus from the editor mid-composition.
toolbar.addEventListener("pointerdown", (e) => { if (e.target.closest("button")) e.preventDefault(); });
toolbar.addEventListener("click", (e) => {
  const button = e.target.closest("button");
  if (!button) return;
  flush();
  if (button.dataset.action) runAction(button.dataset.action);
  else commands.find((c) => c.id === button.dataset.command)?.run();
});

// ---------------------------------------------------------------- bar menu

// The header keeps only the essentials: the sidebar toggle, the note title
// (which opens the switcher), the palette button and this menu. Document and
// app actions live here, anchored under the ⋯ button.
const moreBtn = $("#bar-more-btn");
const barMenu = $("#bar-menu");

function closeBarMenu(refocus = false) {
  if (barMenu.hidden) return;
  barMenu.hidden = true;
  moreBtn.setAttribute("aria-expanded", "false");
  if (refocus) moreBtn.focus({ preventScroll: true });
}

function openBarMenu() {
  barMenu.hidden = false;
  moreBtn.setAttribute("aria-expanded", "true");
  const r = moreBtn.getBoundingClientRect();
  const w = barMenu.offsetWidth;
  const h = barMenu.offsetHeight;
  barMenu.style.left = `${Math.max(8, Math.min(r.right - w, innerWidth - w - 8))}px`;
  barMenu.style.top = `${r.bottom + h + 8 > innerHeight ? Math.max(8, r.top - h - 4) : r.bottom + 4}px`;
  barMenu.querySelector("button")?.focus({ preventScroll: true });
}

moreBtn.addEventListener("pointerdown", (e) => e.preventDefault());
moreBtn.addEventListener("click", () => (barMenu.hidden ? openBarMenu() : closeBarMenu(true)));
barMenu.addEventListener("pointerdown", (e) => { if (e.target.closest("button")) e.preventDefault(); });
barMenu.addEventListener("click", (e) => {
  const button = e.target.closest("button");
  if (!button) return;
  closeBarMenu();
  if (button.dataset.command) {
    flush();
    commands.find((c) => c.id === button.dataset.command)?.run();
  }
  // Commands that open a dialog take focus themselves; the rest go back to the note.
  if (!document.querySelector("dialog[open]")) view.focus();
});
document.addEventListener("pointerdown", (e) => {
  if (barMenu.hidden || barMenu.contains(e.target) || moreBtn.contains(e.target)) return;
  closeBarMenu();
}, true);
document.addEventListener("keydown", (e) => {
  if (e.key !== "Escape" || barMenu.hidden) return;
  e.preventDefault();
  e.stopPropagation();
  closeBarMenu(true);
}, true);

// ----------------------------------------------------------------- sidebar

// Docked beside the note on a wide screen (open or closed is remembered),
// a drawer over it on a narrow one (closed after picking a note).
const SIDEBAR_KEY = "misstype-editor-sidebar";
const narrowSidebar = matchMedia("(max-width: 800px)");
const sidebarEl = $("#sidebar");
const sidebar = new Sidebar(sidebarEl, {
  notes,
  current: () => currentId,
  open: openNote,
  create: (folder) => newNote(folder),
  remove: deleteNote,
  close: () => setSidebar(false),
  toast,
});

const sidebarOpen = () => document.body.classList.contains("side-open");
function setSidebar(open) {
  document.body.classList.toggle("side-open", open);
  $("#sidebar-btn").setAttribute("aria-expanded", String(open));
  sidebarEl.inert = !open;
  if (!narrowSidebar.matches) {
    try { localStorage.setItem(SIDEBAR_KEY, open ? "1" : "0"); } catch { /* private mode */ }
  }
  if (open && narrowSidebar.matches) sidebarEl.querySelector(".note.current .row-main")?.focus({ preventScroll: true });
  if (!open && sidebarEl.contains(document.activeElement)) view.focus();
}
function initialSidebar() {
  if (narrowSidebar.matches) return false;
  try { return localStorage.getItem(SIDEBAR_KEY) !== "0"; } catch { return true; }
}
setSidebar(initialSidebar());
narrowSidebar.addEventListener("change", () => setSidebar(initialSidebar()));
$("#side-scrim").addEventListener("click", () => setSidebar(false));
// Sidebar taps settle the composition first, as the toolbar does.
sidebarEl.addEventListener("pointerdown", flush, true);

// Another tab (or the installed app) changed the notes: redraw the list, and
// reload the open note if it was not being edited here.
addEventListener("storage", (e) => {
  if (e.key === RESULT_KEY && e.newValue) finishConnect();
  else if (e.key === "misstype-editor-sync") cloud.publish();
  else if (e.key === workspace.storageKey) {
    workspace.reload();
    workspace.project(notes);
    sidebar.render();
  } else if (e.key === notes.indexKey) {
    const index = notes.load();
    if (!index.notes.some((n) => n.id === currentId)) show(index.current);
    sidebar.render();
  } else if (e.key === `misstype-editor-note:${currentId}` && !saveTimer && !imeState?.preedit) {
    states.delete(currentId);
    show(currentId);
  } else if (e.key?.startsWith("misstype-editor-note:")) {
    states.delete(e.key.slice("misstype-editor-note:".length));
  }
});
// Closing the tab or switching apps must not lose the last 400 ms of typing.
addEventListener("pagehide", saveNow);
document.addEventListener("visibilitychange", () => {
  if (document.hidden) saveNow();
  else scheduleSync(0);
});
// Pull other devices' changes now and then, and as soon as the network is back.
setInterval(() => { if (!document.hidden) scheduleSync(0); }, 120_000);
addEventListener("online", () => scheduleSync(0));

// --------------------------------------------------------------------- zen

// Zen hides the header, toolbar, status strip and sidebar and dims all but
// the block being written (zen.js, editor.css). Esc, the command or the
// corner button leave it.
function setZen(on) {
  closeBarMenu();
  document.body.classList.toggle("zen", on);
  if (on && narrowSidebar.matches) setSidebar(false);
  if (on) toast("專注模式 · Esc 離開");
  if (imeState) panel.place(caretRect());
  view.focus();
}
$("#zen-exit").addEventListener("pointerdown", (e) => e.preventDefault());
$("#zen-exit").addEventListener("click", () => setZen(false));
// Bubbling, so an Esc the decoder used (cancelling a composition) never gets here.
document.addEventListener("keydown", (e) => {
  if (e.key !== "Escape" || e.defaultPrevented || e.isComposing || !document.body.classList.contains("zen")) return;
  if (document.querySelector("dialog[open]")) return;
  e.preventDefault();
  setZen(false);
});

// ------------------------------------------------------------------- about

const aboutDialog = $("#about");
const openAbout = () => aboutDialog.showModal();
aboutDialog.addEventListener("close", () => view.focus());
aboutDialog.addEventListener("pointerdown", (e) => { if (e.target === aboutDialog) aboutDialog.close(); });
aboutDialog.querySelector("[data-close]").addEventListener("click", () => aboutDialog.close());
$("#about-btn").addEventListener("click", () => { flush(); openAbout(); });
$("#vk-btn").addEventListener("click", toggleVirtualKeyboard);

// -------------------------------------------------------------------- sync

/** Syncs `delay` ms from now (again after the last call), if an account is connected. */
function scheduleSync(delay = 4000) {
  if (!cloud.provider) return;
  clearTimeout(syncTimer);
  syncTimer = setTimeout(runSync, delay);
}

async function runSync() {
  clearTimeout(syncTimer);
  syncTimer = 0;
  if (!cloud.provider || cloud.status.needsSignIn) return;
  // A composition belongs to the note on screen; let it finish first.
  if (imeState?.preedit) { scheduleSync(); return; }
  saveNow();
  clearTimeout(syncTimer); // the save just above is part of this pass
  const report = await cloud.sync();
  if (!report) return;
  const replaced = new Set(report.replaced ?? []);
  const contentChanged = new Set(report.contentChanged ?? []);
  for (const id of report.changed) if (id !== currentId) states.delete(id);
  for (const id of contentChanged) if (id !== currentId) states.delete(id);
  const index = notes.load();
  if (!index.notes.some((n) => n.id === currentId)) show(index.current);
  else if ((replaced.has(currentId) || (report.changed.includes(currentId) && !contentChanged.has(currentId)))
    && !saveTimer && !imeState?.preedit) {
    states.delete(currentId);
    show(currentId);
  }
  sidebar.render();
  if (report.conflicts) toast(`${report.conflicts} 篇筆記兩邊都改過，兩個版本都留著`);
  else if (report.merged) toast(`已合併 ${report.merged} 篇筆記`);
}

const timeOf = (ms) => new Date(ms).toLocaleTimeString("zh-TW", { hour: "2-digit", minute: "2-digit" });

/** Draws the sync state in the status strip and in Settings. */
function renderSync(s) {
  const name = s.provider ? PROVIDERS[s.provider].name : "";
  const button = document.querySelector("#sync-btn");
  button.hidden = !s.provider;
  if (s.busy) button.textContent = "同步中⋯";
  else if (s.error) button.textContent = s.error;
  else if (s.last) {
    const label = document.createElement("span");
    label.textContent = "已同步";
    const time = document.createElement("span");
    time.className = "sync-time";
    time.textContent = ` ${timeOf(s.last)}`;
    button.replaceChildren(label, time);
  } else button.textContent = name;
  button.title = s.provider ? `${name}${s.last ? ` · 上次同步 ${timeOf(s.last)}` : ""} · 點一下立即同步` : "";
  const box = document.querySelector("#cloud");
  const offered = Object.keys(PROVIDERS).filter((p) => PROVIDERS[p].configured);
  // No build key and no account: there is nothing to show, and an empty group
  // in Settings only invites the question "why is this here?".
  box.hidden = !s.provider && !offered.length;
  box.querySelector("#cloud-state").textContent = s.provider
    ? `已連結 ${name}${s.last ? `，上次同步 ${timeOf(s.last)}` : ""}${s.error ? `。${s.error}` : ""}`
    : s.error || (offered.length
      ? "筆記目前只存在這個瀏覽器。連結後會存進你自己的雲端（Dropbox 的「應用程式」資料夾，或 Google Drive 的 Misstype 資料夾），在每台裝置連結同一個帳號即可共用。"
      : "這個網站沒有設定雲端同步。");
  for (const el of box.querySelectorAll("[data-cloud]")) {
    const what = el.dataset.cloud;
    if (what in PROVIDERS) {
      const again = s.needsSignIn && s.provider === what;
      el.hidden = !PROVIDERS[what].configured || (Boolean(s.provider) && !again);
      el.textContent = `${again ? "重新登入" : "連結"} ${PROVIDERS[what].name}`;
    } else {
      el.hidden = !s.provider;
      el.disabled = what === "sync" && (s.busy || s.needsSignIn);
    }
  }
}

async function finishConnect() {
  if (!await cloud.finish()) return;
  toast(`已連結 ${PROVIDERS[cloud.provider].name}`);
  runSync();
}

document.querySelector("#cloud").addEventListener("click", (e) => {
  const what = e.target.closest("[data-cloud]")?.dataset.cloud;
  if (!what) return;
  if (what in PROVIDERS) {
    saveNow();
    cloud.connect(what);
  } else if (what === "sync") {
    runSync();
  } else if (what === "disconnect" && confirm(`中斷與 ${PROVIDERS[cloud.provider].name} 的連結？這台裝置和雲端上的筆記都會留著。`)) {
    clearTimeout(syncTimer);
    cloud.disconnect();
  }
});
$("#sync-btn").addEventListener("click", () => {
  flush();
  if (cloud.status.needsSignIn) openSettings();
  else runSync();
});

// ---------------------------------------------------------------- settings

const settingsDialog = $("#settings");

function openSettings() {
  for (const el of settingsDialog.querySelectorAll("[data-setting]")) {
    const value = settings[el.dataset.setting];
    if (el.type === "checkbox") el.checked = value;
    else el.value = String(value);
  }
  syncLearningOptions();
  settingsDialog.showModal();
  // Land on the candidates-per-page select (focused, list closed).
  settingsDialog.querySelector('[data-setting="pageSize"]').focus();
}

settingsDialog.addEventListener("change", (e) => {
  const el = e.target.closest("[data-setting]");
  if (!el) return;
  const raw = el.type === "checkbox" ? el.checked : el.value;
  setSetting(el.dataset.setting, typeof settings[el.dataset.setting] === "number" ? Number(raw) : raw);
  syncLearningOptions();
});
// Slip learning builds on phrase learning, as on desktop.
function syncLearningOptions() {
  settingsDialog.querySelector('[data-setting="channelLearning"]').disabled = !settings.userLearning;
}
settingsDialog.addEventListener("close", () => view.focus());
settingsDialog.addEventListener("pointerdown", (e) => { if (e.target === settingsDialog) settingsDialog.close(); });
settingsDialog.querySelector("[data-open-dictionary]").addEventListener("click", () => {
  settingsDialog.close();
  dictionary.open();
});
settingsDialog.querySelector("[data-open-learning]").addEventListener("click", () => {
  settingsDialog.close();
  learning.open();
});
settingsDialog.querySelector("[data-close]").addEventListener("click", () => settingsDialog.close());

// -------------------------------------------------------------------- boot

applyAppearance();
updateCount();
updateToolbar();
sidebar.render();
renderDocTitle();

// Capture on the editor so the decoder sees keys before ProseMirror's handlers.
const host = view.dom;
host.addEventListener("keydown", keyDown, true);
host.addEventListener("keyup", keyUp, true);
host.addEventListener("pointerdown", flush, true);
host.addEventListener("focusout", () => setTimeout(() => {
  if (host.contains(document.activeElement)) return;
  if (performance.now() < vkTouchUntil) { view.focus(); return; }
  flush();
}));
host.addEventListener("compositionstart", flush);
host.addEventListener("focusin", () => {
  if (!vkDismissed) return;
  vkDismissed = false;
  applyVirtualKeyboard();
});
addEventListener("resize", () => panel.place(caretRect()));
visualViewport?.addEventListener("resize", () => panel.place(caretRect()));

// The margins around the document block belong to the editor too.
$("#editor").addEventListener("mousedown", (e) => {
  if (e.target !== e.currentTarget) return;
  e.preventDefault();
  view.focus();
});

for (const el of document.querySelectorAll("[data-command]")) {
  const command = commands.find((c) => c.id === el.dataset.command);
  if (command?.chord) el.title = `${el.getAttribute("aria-label") || el.textContent.trim()} (${command.chord})`;
}
// Header buttons must not take focus from the editor mid-composition either.
$(".bar").addEventListener("pointerdown", (e) => { if (e.target.closest("button")) e.preventDefault(); });
$(".bar").addEventListener("click", (e) => {
  const button = e.target.closest("[data-command]");
  if (!button) return;
  flush();
  commands.find((c) => c.id === button.dataset.command)?.run();
});

loadIme();
cloud.publish();
// Back from a full-page sign-in (popup blocked), or a sync on load.
finishConnect();
scheduleSync(1000);
registerServiceWorker((state) => {
  $("#offline").textContent = state;
});
view.focus();
