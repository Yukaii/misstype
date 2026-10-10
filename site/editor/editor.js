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
import { actions, editingKeys } from "./actions.js";
import { CandidatePanel } from "./candidates.js";
import { chord, isApple, matches, modifierBits } from "./keys.js";
import { parseMarkdown, schema, toMarkdown, wordCount } from "./model.js";
import { createDictionary } from "./dictionary.js";
import { createLearning } from "./learning.js";
import { tick } from "./haptics.js";
import { VirtualKeyboard } from "./keyboard.js";
import { Palette } from "./palette.js";
import { preeditKey, preeditPlugin, setPreedit } from "./preedit.js";
import { registerServiceWorker } from "./pwa.js";
import { markdownRules } from "./rules.js";
import { IME_KEYS, loadSettings, saveSettings } from "./settings.js";

const DOC_KEY = "misstype-editor-md";
const $ = (sel) => document.querySelector(sel);

const settings = loadSettings();
const app = $(".pg");
const toastEl = $("#toast");
const modeLabel = $("#mode-label");
const modeFlash = $("#mode-flash");
const countEl = $("#count");

let ime = null;
let imeState = null;
let nativeImeKeys = 0;

// ---------------------------------------------------------------- document

const readStored = () => {
  try { return localStorage.getItem(DOC_KEY) || ""; } catch { return ""; }
};

let saveTimer = 0;
function scheduleSave() {
  clearTimeout(saveTimer);
  saveTimer = setTimeout(() => {
    try { localStorage.setItem(DOC_KEY, toMarkdown(view.state.doc)); } catch { /* storage full or private mode */ }
  }, 400);
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

function createView() {
  return new EditorView($("#editor"), {
    state: EditorState.create({
      doc: parseMarkdown(readStored()),
      plugins: [
        markdownRules,
        history(),
        keymap({ ...editingKeys, "Mod-z": undo, "Mod-y": redo, "Shift-Mod-z": redo }),
        keymap(baseKeymap),
        dropCursor(),
        preeditPlugin,
        placeholder,
      ],
    }),
    // Pasted plain text is read as Markdown, so notes from other editors keep their structure.
    clipboardTextParser: (text, $context, plain) => {
      if (plain) return undefined;
      return new Slice(parseMarkdown(text).content, 0, 0);
    },
    dispatchTransaction(tr) {
      view.updateState(view.state.apply(tr));
      if (tr.docChanged) {
        scheduleSave();
        countEl.textContent = `${wordCount(view.state.doc).total} 字`;
      }
      updateToolbar();
    },
  });
}

const view = createView();

// The window scrolls under the sticky header, toolbar and status strip, so keep
// the caret clear of them when ProseMirror scrolls it into view.
function keepCaretClear() {
  const top = $(".chrome").offsetHeight + 12;
  // The docked candidate bar sits right above the keyboard.
  const bottom = $(".status").offsetHeight + vkHeight() + (vkEl.hidden ? 0 : 48) + 24;
  view.setProps({ scrollMargin: { top, bottom, left: 8, right: 8 }, scrollThreshold: { top, bottom, left: 8, right: 8 } });
}

function runAction(id) {
  actions[id].run(view.state, view.dispatch, view);
  view.focus();
}

// --------------------------------------------------------------------- IME

const panel = new CandidatePanel(app, {
  onPick: (index) => { ime?.pick(index); sync(); view.focus(); },
  onPage: (code) => { ime?.key(code, code, 0, 0); sync(); view.focus(); },
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
  let tr = view.state.tr;
  if (text) tr = tr.insertText(text).scrollIntoView();
  view.dispatch(setPreedit(tr, imeState.preedit ? imeState : null));
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

// Touch devices without a keyboard get an on-screen mini QWERTY. Its keys are
// replayed as ordinary KeyboardEvents on the editor, so the decoder, settings
// and ProseMirror's keymaps see exactly what a hardware keyboard would send.
const vkEl = $("#vk");
vkEl.dataset.platform = /Android/i.test(navigator.userAgent) ? "android" : "ios";
const touchOnly = matchMedia("(pointer: coarse) and (hover: none)");
let hardwareKeyboardSeen = false;

const vkHeight = () => (vkEl.hidden ? 0 : vkEl.offsetHeight);

function virtualKeyboardWanted() {
  const mode = settings.virtualKeyboard;
  return mode === "on" || (mode === "auto" && touchOnly.matches && !hardwareKeyboardSeen);
}

function applyVirtualKeyboard() {
  const on = virtualKeyboardWanted();
  vkEl.hidden = !on;
  document.body.classList.toggle("vk-on", on);
  panel.setDocked(on);
  if (imeState) panel.render(imeState, caretRect());
  // Without this the system keyboard would pop up over ours.
  view.setProps({ attributes: on ? { inputmode: "none" } : {} });
  document.documentElement.style.setProperty("--vk-h", `${vkHeight()}px`);
  keepCaretClear();
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
  if (!e.isTrusted || e.isComposing || e.keyCode === 229 || e.key === "Unidentified" || hardwareKeyboardSeen) return;
  hardwareKeyboardSeen = true;
  if (settings.virtualKeyboard === "auto") applyVirtualKeyboard();
}, true);
touchOnly.addEventListener("change", applyVirtualKeyboard);
new ResizeObserver(() => {
  document.documentElement.style.setProperty("--vk-h", `${vkHeight()}px`);
  keepCaretClear();
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
  const a = Object.assign(document.createElement("a"), { href: url, download: "note.md" });
  document.body.append(a);
  a.click();
  a.remove();
  setTimeout(() => URL.revokeObjectURL(url), 1000);
}

/** Replaces the whole note with a Markdown file; one undo brings the old one back. */
function importFile() {
  const input = Object.assign(document.createElement("input"), { type: "file", accept: ".md,.markdown,.txt,text/markdown,text/plain" });
  input.addEventListener("change", async () => {
    const file = input.files?.[0];
    if (!file) return;
    const doc = parseMarkdown(await file.text());
    view.dispatch(view.state.tr.replaceWith(0, view.state.doc.content.size, doc.content).scrollIntoView());
    toast(`已匯入 ${file.name}`);
    view.focus();
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
  { id: "clear", title: "清空內容", keywords: "clear delete empty 清除", combo: "Mod-Shift-k", chord: chord("Mod-Shift-k"), run: clearAll },
  { id: "download", title: "下載 .md 檔", keywords: "download save export 儲存", combo: "Mod-s", chord: chord("Mod-s"), run: download },
  { id: "import", title: "匯入 Markdown 檔", keywords: "import open file 開啟", combo: "Mod-o", chord: chord("Mod-o"), run: importFile },
  { id: "mode", title: "切換中／英", keywords: "english chinese mode 中英", combo: "Mod-Shift-e", chord: chord("Mod-Shift-e") + " · 輕按 Shift", run: toggleMode },
  { id: "dictionary", title: "我的詞庫", keywords: "dictionary words phrases user 詞庫 詞彙", combo: "Mod-Shift-d", chord: chord("Mod-Shift-d"), run: () => dictionary.open() },
  { id: "learning", title: "學習資料", keywords: "learning learned phrases slips forget 學習 學到的詞 打錯", run: () => learning.open() },
  { id: "about", title: "關於", keywords: "about info help 說明 介紹", run: () => openAbout() },
  { id: "settings", title: "設定", keywords: "settings options preferences 選項", combo: "Mod-,", chord: chord("Mod-,"), run: () => openSettings() },
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
  { id: "bold", title: "粗體", keywords: "bold strong", chord: chord("Mod-b"), run: act("bold") },
  { id: "italic", title: "斜體", keywords: "italic emphasis", chord: chord("Mod-i"), run: act("italic") },
  { id: "inline-code", title: "行內程式碼", keywords: "code", chord: chord("Mod-`"), run: act("code") },
  { id: "undo", title: "復原", keywords: "undo", chord: chord("Mod-z"), run: () => { undo(view.state, view.dispatch); view.focus(); } },
  { id: "redo", title: "重做", keywords: "redo", chord: chord(isApple ? "Mod-Shift-z" : "Mod-y"), run: () => { redo(view.state, view.dispatch); view.focus(); } },
];

const palette = new Palette(() => commands);
palette.onClose = () => view.focus();

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

// ------------------------------------------------------------------- about

const aboutDialog = $("#about");
const openAbout = () => aboutDialog.showModal();
aboutDialog.addEventListener("close", () => view.focus());
aboutDialog.addEventListener("pointerdown", (e) => { if (e.target === aboutDialog) aboutDialog.close(); });
aboutDialog.querySelector("[data-close]").addEventListener("click", () => aboutDialog.close());
$("#about-btn").addEventListener("click", () => { flush(); openAbout(); });

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

keepCaretClear();
addEventListener("resize", keepCaretClear);
applyAppearance();
countEl.textContent = `${wordCount(view.state.doc).total} 字`;
updateToolbar();

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
registerServiceWorker((state) => {
  $("#offline").textContent = state;
});
view.focus();
