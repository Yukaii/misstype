import { Wordgard, menuBar, placeholder } from "wordgard/editor";
import { Command, insertText, deleteSelection, selectAll, undo, redo, toggleStrong, toggleEmphasis, toggleBlock, toggleList, setTextblockType } from "wordgard/command";
import { fullSchema } from "wordgard/schema";
import { history } from "wordgard/history";
import { Blockquote, BulletList, CodeBlock, Heading, OrderedList, Paragraph } from "wordgard/types";
import MisstypeWasm from "../../packages/misstype-wasm/src/index.js";
import "../playground.css";
import "./editor.css";
import { CandidatePanel } from "./candidates.js";
import { Palette } from "./palette.js";
import { chord, hasMod, isApple, matches, modifierBits } from "./keys.js";
import { toMarkdown, wordCount } from "./markdown.js";
import { IME_KEYS, loadSettings, saveSettings } from "./settings.js";
import { inlineRules } from "./inline-rules.js";
import { registerServiceWorker } from "./pwa.js";

const DOC_KEY = "misstype-editor-doc";
const $ = (sel) => document.querySelector(sel);

const settings = loadSettings();
const app = $(".pg");
const toastEl = $("#toast");
const modeBtn = $("#mode-btn");
const countEl = $("#count");

let ime = null;
let imeState = null;
let wg = null;

// ---------------------------------------------------------------- document

function savedDoc() {
  try { return JSON.parse(localStorage.getItem(DOC_KEY)); } catch { return null; }
}

let saveTimer = 0;
function scheduleSave() {
  clearTimeout(saveTimer);
  saveTimer = setTimeout(() => {
    try { localStorage.setItem(DOC_KEY, JSON.stringify(wg.state.doc.toJSON())); } catch { /* storage full or private mode */ }
  }, 400);
}

function createEditor() {
  const make = (doc) => Wordgard.create({
    parent: $("#editor"),
    doc,
    config: [
      fullSchema(),
      history(),
      menuBar(),
      inlineRules,
      placeholder("開始打字⋯ 打 # 加空白是標題，- 加空白是清單。"),
      Wordgard.updateListener.of((update) => {
        if (!update.docChanged) return;
        scheduleSave();
        const { total } = wordCount(update.state.doc);
        countEl.textContent = `${total} 字`;
      }),
    ],
  });
  const stored = savedDoc();
  try {
    return make(stored ?? "<p></p>");
  } catch (err) {
    console.warn("saved document could not be restored", err);
    $("#editor").replaceChildren();
    return make("<p></p>");
  }
}

function run(command, param) {
  const ok = param === undefined ? Command.dispatch(wg, command) : Command.dispatch(wg, command, param);
  wg.focus();
  return ok;
}

function insert(text) {
  const { from, to } = wg.state.selection.replacementRange;
  const spec = insertText({ state: wg.state }, { from, to, insert: text, userEvent: "input.type" });
  if (spec) wg.dispatch({ ...spec, scrollIntoView: true });
}

// --------------------------------------------------------------------- IME

const panel = new CandidatePanel(app, {
  onPick: (index) => { ime?.pick(index); sync(); wg.focus(); },
  onPage: (code) => { ime?.key(code, code, 0, 0); sync(); wg.focus(); },
});

function caretRect() {
  try {
    return wg.coordsAtPos(wg.state.selection.head);
  } catch {
    return $("#editor").getBoundingClientRect();
  }
}

/** Moves finished text into the document and redraws the composition bar. */
function sync() {
  if (!ime) return;
  const text = ime.takeCommitted();
  if (text) insert(text);
  imeState = ime.state();
  panel.render(imeState, caretRect());
  const english = imeState.english;
  modeBtn.textContent = english ? "英" : "中";
  modeBtn.classList.toggle("english", english || imeState.latinActive);
}

/** Settles an unfinished composition so the editor can act on real text. */
function flush() {
  if (ime && imeState?.preedit && ime.commit()) sync();
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
  // Document shortcuts belong to Wordgard; settle the composition first.
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
  sync();
}

function keyUp(e) {
  if (!ime || (e.code !== "ShiftLeft" && e.code !== "ShiftRight")) return;
  if (ime.key(e.code, e.key, modifierBits(e), 1)) e.preventDefault();
  sync();
}

let nativeImeKeys = 0;

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

const plainText = () => wg.state.doc.textContent({ blockSeparator: "\n" });

function download() {
  const url = URL.createObjectURL(new Blob([toMarkdown(wg.state.doc)], { type: "text/markdown;charset=utf-8" }));
  const a = Object.assign(document.createElement("a"), { href: url, download: "note.md" });
  document.body.append(a);
  a.click();
  a.remove();
  setTimeout(() => URL.revokeObjectURL(url), 1000);
}

function clearAll() {
  run(selectAll);
  const spec = deleteSelection(wg.state);
  if (spec) wg.dispatch(spec);
  toast(`已清空（${chord("Mod-z")} 可復原）`);
}

function toggleMode() {
  if (!ime) return;
  ime.toggleEnglish();
  sync();
  wg.focus();
}

function cycle(list, current) {
  return list[(list.indexOf(current) + 1) % list.length];
}

function setSetting(key, value) {
  settings[key] = value;
  saveSettings(settings);
  applyAppearance();
  if (IME_KEYS.includes(key)) applyImeSettings();
}

const heading = (n) => () => run(setTextblockType, Heading.of(n));

const commands = [
  { id: "palette", title: "指令選單", chord: chord("Mod-Shift-p"), combo: "Mod-Shift-p", run: () => palette.open() },
  { id: "copy-md", title: "複製為 Markdown", keywords: "copy markdown 複製", combo: "Mod-Shift-c", chord: chord("Mod-Shift-c"),
    run: () => copyText(toMarkdown(wg.state.doc), "已複製 Markdown") },
  { id: "copy-text", title: "複製為純文字", keywords: "copy plain text 複製", combo: "Mod-Shift-x", chord: chord("Mod-Shift-x"),
    run: () => copyText(plainText(), "已複製純文字") },
  { id: "clear", title: "清空內容", keywords: "clear delete empty 清除", combo: "Mod-Shift-k", chord: chord("Mod-Shift-k"), run: clearAll },
  { id: "download", title: "下載 .md 檔", keywords: "download save export 儲存", combo: "Mod-s", chord: chord("Mod-s"), run: download },
  { id: "mode", title: "切換中／英", keywords: "english chinese mode 中英", combo: "Mod-Shift-e", chord: chord("Mod-Shift-e") + " · 輕按 Shift", run: toggleMode },
  { id: "settings", title: "設定", keywords: "settings options preferences 選項", combo: "Mod-,", chord: chord("Mod-,"), run: () => openSettings() },
  { id: "layout", title: "候選窗：直式／橫式", keywords: "candidate layout vertical horizontal",
    run: () => setSetting("candidateLayout", settings.candidateLayout === "vertical" ? "horizontal" : "vertical") },
  { id: "theme", title: "切換淺色／深色", keywords: "theme dark light 主題", run: () => $(".theme-toggle").click() },
  { id: "h1", title: "標題 1", keywords: "heading", chord: "Ctrl+Shift+1", run: heading(1) },
  { id: "h2", title: "標題 2", keywords: "heading", chord: "Ctrl+Shift+2", run: heading(2) },
  { id: "h3", title: "標題 3", keywords: "heading", chord: "Ctrl+Shift+3", run: heading(3) },
  { id: "p", title: "一般段落", keywords: "paragraph", chord: "Ctrl+Shift+0", run: () => run(setTextblockType, Paragraph) },
  { id: "ul", title: "項目清單", keywords: "bullet list", run: () => run(toggleList, BulletList) },
  { id: "ol", title: "編號清單", keywords: "ordered numbered list", run: () => run(toggleList, OrderedList) },
  { id: "quote", title: "引用", keywords: "blockquote", run: () => run(toggleBlock, Blockquote) },
  { id: "code", title: "程式碼區塊", keywords: "code block", run: () => run(toggleBlock, CodeBlock) },
  { id: "bold", title: "粗體", keywords: "bold strong", chord: chord("Mod-b"), run: () => run(toggleStrong) },
  { id: "italic", title: "斜體", keywords: "italic emphasis", chord: chord("Mod-i"), run: () => run(toggleEmphasis) },
  { id: "undo", title: "復原", keywords: "undo", chord: chord("Mod-z"), run: () => run(undo) },
  { id: "redo", title: "重做", keywords: "redo", chord: chord(isApple ? "Mod-Shift-z" : "Mod-y"), run: () => run(redo) },
  { id: "select-all", title: "全選", keywords: "select all", chord: chord("Mod-a"), run: () => run(selectAll) },
];

const palette = new Palette(() => commands);
palette.onClose = () => wg.focus();

document.addEventListener("keydown", (e) => {
  if (palette.isOpen || settingsDialog.open || e.isComposing) return;
  const command = commands.find((c) => c.combo && matches(e, c.combo))
    || (e.key === "F1" && commands[0]);
  if (!command) return;
  e.preventDefault();
  e.stopPropagation();
  flush();
  command.run();
}, true);

// ---------------------------------------------------------------- settings

const settingsDialog = $("#settings");

function openSettings() {
  for (const el of settingsDialog.querySelectorAll("[data-setting]")) {
    const value = settings[el.dataset.setting];
    if (el.type === "checkbox") el.checked = value;
    else el.value = String(value);
  }
  settingsDialog.showModal();
}

settingsDialog.addEventListener("change", (e) => {
  const el = e.target.closest("[data-setting]");
  if (!el) return;
  const raw = el.type === "checkbox" ? el.checked : el.value;
  setSetting(el.dataset.setting, typeof settings[el.dataset.setting] === "number" ? Number(raw) : raw);
});
settingsDialog.addEventListener("close", () => wg.focus());
settingsDialog.addEventListener("pointerdown", (e) => { if (e.target === settingsDialog) settingsDialog.close(); });
settingsDialog.querySelector("[data-close]").addEventListener("click", () => settingsDialog.close());

// -------------------------------------------------------------------- boot

wg = createEditor();
applyAppearance();
countEl.textContent = `${wordCount(wg.state.doc).total} 字`;

// Capture on the wrapper so the decoder sees keys before Wordgard's own handlers.
const host = $("#editor");
host.addEventListener("keydown", keyDown, true);
host.addEventListener("keyup", keyUp, true);
host.addEventListener("pointerdown", flush, true);
host.addEventListener("focusout", () => setTimeout(() => { if (!host.contains(document.activeElement)) flush(); }));
host.addEventListener("compositionstart", flush);
addEventListener("resize", () => panel.place(caretRect()));
visualViewport?.addEventListener("resize", () => panel.place(caretRect()));

modeBtn.addEventListener("click", toggleMode);
$("#palette-btn").addEventListener("click", () => { flush(); palette.open(); });
$("#settings-btn").addEventListener("click", () => { flush(); openSettings(); });
$("#copy-btn").addEventListener("click", () => { flush(); copyText(toMarkdown(wg.state.doc), "已複製 Markdown"); });
$("#clear-btn").addEventListener("click", () => { flush(); clearAll(); wg.focus(); });
// Buttons must not take focus from the editor mid-composition.
document.querySelector(".bar").addEventListener("pointerdown", (e) => { if (e.target.closest("button")) e.preventDefault(); });

for (const el of document.querySelectorAll("[data-command]")) {
  const command = commands.find((c) => c.id === el.dataset.command);
  if (command?.chord) el.title = `${el.getAttribute("aria-label") || el.textContent.trim()} (${command.chord})`;
}

loadIme();
registerServiceWorker((state) => {
  $("#offline").textContent = state;
});
wg.focus();
