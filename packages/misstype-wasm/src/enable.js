import MisstypeWasm from "./index.js";

/**
 * Turns the Misstype Zhuyin decoder on for a web page's text fields.
 *
 * `enable()` loads the wasm module once and listens (capture phase, on the
 * document) for key events in `<textarea>`, text-like `<input>` and
 * `contenteditable` elements, so fields added later work too. Keys the decoder
 * consumes never reach the page; finished text is inserted as a normal edit
 * (`insertText`, so undo and the page's own `input` handlers keep working).
 * Pre-edit text and candidates are drawn in a floating window beside the caret,
 * inside a shadow root so page CSS cannot touch it. Nothing leaves the browser.
 */

const DEFAULT_SELECTOR = [
  "textarea",
  'input:not([type])',
  'input[type="text"]',
  'input[type="search"]',
  '[contenteditable]:not([contenteditable="false"])',
].join(",");

const DEFAULT_SETTINGS = {
  pageSize: 9,
  shiftToggle: true,
  returnConfirmsSelection: true,
  autoShowCandidates: true,
  userLearning: true,
  channelLearning: false,
};

const MIRRORED = [
  "direction", "boxSizing", "width", "height", "overflowX", "overflowY", "borderTopWidth", "borderRightWidth",
  "borderBottomWidth", "borderLeftWidth", "borderStyle", "paddingTop", "paddingRight", "paddingBottom",
  "paddingLeft", "fontStyle", "fontVariant", "fontWeight", "fontStretch", "fontSize", "fontSizeAdjust",
  "lineHeight", "fontFamily", "textAlign", "textTransform", "textIndent", "letterSpacing", "wordSpacing", "tabSize",
];

const CSS = `
:host { all: initial; }
.panel { position: fixed; z-index: 2147483647; min-width: 160px; max-width: min(360px, calc(100vw - 16px));
  box-sizing: border-box; padding: 6px; border: 1px solid var(--line); border-radius: 8px; background: var(--bg); color: var(--fg);
  box-shadow: 0 12px 32px rgba(0,0,0,.18), 0 2px 6px rgba(0,0,0,.1); font: 16px/1.4 system-ui, -apple-system, "PingFang TC", "Noto Sans TC", "Microsoft JhengHei", sans-serif;
  user-select: none; -webkit-user-select: none; }
.panel[hidden], .flash[hidden] { display: none; }
.pre { padding: 2px 8px 6px; font-size: 18px; border-bottom: 1px solid var(--line); white-space: pre; overflow: hidden; text-overflow: ellipsis; }
.seg { border-bottom: 2px solid var(--fg); padding-bottom: 1px; }
.seg.focused { border-bottom-color: var(--accent); }
.marked { background: var(--hl); border-radius: 3px; }
.caret { display: inline-block; width: 0; height: 1.1em; margin: 0 -1px; border-left: 2px solid var(--fg); vertical-align: -.15em; animation: blink 1.1s steps(1) infinite; }
.hint { margin-left: 8px; font-size: 12px; color: var(--accent); }
@keyframes blink { 50% { opacity: 0; } }
.list { display: flex; flex-direction: column; gap: 2px; margin-top: 4px; }
.panel.horizontal .list { flex-direction: row; flex-wrap: wrap; }
.item { display: flex; align-items: center; justify-content: space-between; gap: 14px; padding: 5px 10px; border-radius: 6px; cursor: pointer; font-size: 17px; }
.item:hover, .item.selected { background: var(--hl); }
.key { font: 600 12px ui-monospace, Menlo, monospace; color: var(--accent); min-width: 1.2em; text-align: center; }
.foot { display: flex; justify-content: space-between; align-items: center; padding: 4px 8px 0; margin-top: 4px; border-top: 1px solid var(--line); font-size: 12px; color: var(--muted); }
.foot button { font: inherit; border: 1px solid var(--line); border-radius: 4px; background: none; color: var(--muted); padding: 0 7px; cursor: pointer; }
.foot button:disabled { opacity: .3; cursor: default; }
.flash { position: fixed; z-index: 2147483647; padding: 1px 8px; border-radius: 6px; font: 600 15px/1.5 system-ui, sans-serif; background: var(--fg); color: var(--bg); pointer-events: none; opacity: 0; }
.flash.english { background: #1a4f8b; color: #fff; }
.flash.show { animation: flash 1.3s ease-out forwards; }
@keyframes flash { 0%, 70% { opacity: .95; } 100% { opacity: 0; } }
:host { --bg: #fff; --fg: #262c34; --line: #dedad1; --muted: #5f6672; --hl: #ede9e1; --accent: #b5462f; }
:host([data-scheme="dark"]) { --bg: #1b1e26; --fg: #e8eaf0; --line: #333949; --muted: #9aa1b0; --hl: #2c3140; --accent: #ff8a6b; }
`;

const escapeHtml = (s) => s.replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#039;" }[c]));

function modifierBits(e) {
  return (e.shiftKey ? 1 : 0) | (e.ctrlKey ? 2 : 0) | (e.altKey ? 4 : 0) | (e.metaKey ? 8 : 0)
    | (e.getModifierState?.("CapsLock") ? 16 : 0);
}

/** Screen box of the caret in a field (a mirror element measures `<input>` / `<textarea>`). */
function caretBox(el) {
  if (el.isContentEditable) {
    const selection = getSelection();
    if (selection?.rangeCount) {
      const range = selection.getRangeAt(0).cloneRange();
      range.collapse(false);
      const rects = range.getClientRects();
      const rect = rects.length ? rects[rects.length - 1] : range.getBoundingClientRect();
      if (rect.height || rect.width || rect.top) return rect;
    }
    return el.getBoundingClientRect();
  }
  const style = getComputedStyle(el);
  const mirror = document.createElement("div");
  for (const prop of MIRRORED) mirror.style[prop] = style[prop];
  Object.assign(mirror.style, {
    position: "absolute", top: "0", left: "-9999px", visibility: "hidden",
    whiteSpace: el.tagName === "INPUT" ? "nowrap" : "pre-wrap", overflowWrap: "break-word",
  });
  const end = el.selectionEnd ?? el.value.length;
  mirror.textContent = el.value.slice(0, end);
  const marker = document.createElement("span");
  marker.textContent = el.value.slice(end) || ".";
  mirror.append(marker);
  document.body.append(mirror);
  const box = el.getBoundingClientRect();
  const left = box.left + marker.offsetLeft + parseFloat(style.borderLeftWidth) - el.scrollLeft;
  const top = box.top + marker.offsetTop + parseFloat(style.borderTopWidth) - el.scrollTop;
  const height = parseFloat(style.lineHeight) || parseFloat(style.fontSize) * 1.25;
  mirror.remove();
  return { left: Math.min(Math.max(left, box.left), box.right), right: left, top, bottom: top + height };
}

/** Inserts finished text as an ordinary edit so undo and page listeners see it. */
function insertText(el, text) {
  if (document.execCommand?.("insertText", false, text)) return;
  if (typeof el.setRangeText === "function") {
    el.setRangeText(text, el.selectionStart, el.selectionEnd, "end");
    el.dispatchEvent(new InputEvent("input", { bubbles: true, inputType: "insertText", data: text }));
  }
}

/**
 * @param {object} [options]
 * @param {string} [options.assets] Base URL of `misstype.wasm`, `lexicon.tsv`, `toneless.tsv`, `english.tsv`.
 * @param {string} [options.selector] Which elements to enable (default: text fields and contenteditable).
 * @param {object} [options.settings] pageSize (4–10), shiftToggle, returnConfirmsSelection, autoShowCandidates,
 *   userLearning (remember explicit picks, default on), channelLearning (learn typing slips, experimental, default off).
 * @param {"vertical"|"horizontal"} [options.layout]
 * @param {"auto"|"light"|"dark"} [options.theme]
 * @param {string|null} [options.storageKey] localStorage key for the user dictionary (`null`: keep it in memory only).
 * @param {string|null} [options.learningKey] localStorage key for the learned phrases; learned typing slips go to
 *   `<key>-slips` (`null`: keep them in memory only).
 * @param {(on: boolean) => void} [options.onNativeIme] Called when a system IME seems to be taking the keys.
 */
export async function enable(options = {}) {
  const assets = new URL(options.assets ?? "./", options.assets ? document.baseURI : import.meta.url);
  const at = (name) => new URL(name, assets).href;
  const selector = options.selector ?? DEFAULT_SELECTOR;
  const storageKey = options.storageKey === undefined ? "misstype-user-dictionary" : options.storageKey;
  const learningKey = options.learningKey === undefined ? "misstype-learned" : options.learningKey;
  const settings = { ...DEFAULT_SETTINGS, ...options.settings };
  let layout = options.layout ?? "vertical";

  const ime = await MisstypeWasm.load({
    wasmUrl: at("misstype.wasm"),
    lexiconUrl: at("lexicon.tsv"),
    tonelessUrl: at("toneless.tsv"),
    englishUrl: at("english.tsv"),
  });
  const readStored = (key) => {
    try { return key ? localStorage.getItem(key) || "" : ""; } catch { return ""; }
  };
  const writeStored = (key, text) => {
    try { if (key) localStorage.setItem(key, text); } catch { /* storage unavailable */ }
  };
  const stored = readStored(storageKey);
  if (stored) ime.setUserDictionary(stored);
  let knownWords = ime.userDictionaryCount();
  const slipsKey = learningKey && `${learningKey}-slips`;
  const learnedPhrases = readStored(learningKey);
  if (learnedPhrases) ime.loadLearned(learnedPhrases);
  const learnedSlips = readStored(slipsKey);
  if (learnedSlips) ime.loadChannel(learnedSlips);
  let knownLearning = ime.learningRevision();
  const applySettings = () => { for (const [k, v] of Object.entries(settings)) ime.setSetting(k, v); };
  applySettings();

  // ---- UI (shadow root, so page styles cannot reach it)
  const host = document.createElement("misstype-ime");
  const root = host.attachShadow({ mode: "open" });
  root.innerHTML = `<style>${CSS}</style>
    <div class="panel" hidden><div class="pre"></div><div class="list"></div>
      <div class="foot"><span>候選字</span><span><button data-page="PageUp" aria-label="上一頁">‹</button> <span class="page"></span> <button data-page="PageDown" aria-label="下一頁">›</button></span></div></div>
    <div class="flash" hidden></div>`;
  document.body.append(host);
  const panel = root.querySelector(".panel");
  const preEl = root.querySelector(".pre");
  const listEl = root.querySelector(".list");
  const pageEl = root.querySelector(".page");
  const prev = root.querySelector('[data-page="PageUp"]');
  const next = root.querySelector('[data-page="PageDown"]');
  const flashEl = root.querySelector(".flash");
  const scheme = matchMedia("(prefers-color-scheme: dark)");
  const paintScheme = () => {
    const dark = (options.theme ?? "auto") === "dark" || ((options.theme ?? "auto") === "auto" && scheme.matches);
    if (dark) host.dataset.scheme = "dark"; else delete host.dataset.scheme;
  };
  paintScheme();
  scheme.addEventListener?.("change", paintScheme);
  panel.classList.toggle("horizontal", layout === "horizontal");

  let active = null; // the element the current composition belongs to
  let state = null;
  let nativeKeys = 0;

  const targetOf = (e) => {
    const raw = e.composedPath?.()[0] ?? e.target;
    if (!(raw instanceof Element) || raw.closest("misstype-ime")) return null;
    const el = raw.closest(selector);
    if (!el) return null;
    if (el.disabled || el.readOnly || el.dataset?.misstype === "off" || el.closest?.('[data-misstype="off"]')) return null;
    if (el.inputMode === "none") return null;
    return el;
  };

  function place(box) {
    if (panel.hidden || !box) return;
    const vv = window.visualViewport;
    const left0 = vv?.offsetLeft || 0, top0 = vv?.offsetTop || 0;
    const width = vv?.width || innerWidth, height = vv?.height || innerHeight;
    const w = panel.offsetWidth, h = panel.offsetHeight;
    const left = Math.max(left0 + 8, Math.min(box.left, left0 + width - w - 8));
    let top = box.bottom + 6;
    if (top + h > top0 + height - 8) top = box.top - h - 6;
    panel.style.left = `${left}px`;
    panel.style.top = `${Math.max(top0 + 8, top)}px`;
  }

  function flash(english, box) {
    flashEl.hidden = false;
    flashEl.textContent = english ? "英" : "中";
    flashEl.classList.toggle("english", english);
    flashEl.style.left = `${Math.round(box.left + 6)}px`;
    flashEl.style.top = `${Math.round(box.top - 26)}px`;
    flashEl.classList.remove("show");
    void flashEl.offsetWidth;
    flashEl.classList.add("show");
  }

  function paint() {
    if (!state?.preedit) {
      panel.hidden = true;
      return;
    }
    const text = state.preedit;
    const segments = state.segments?.length ? state.segments : [[0, text.length]];
    const caret = Math.max(0, Math.min(text.length, state.caret));
    preEl.innerHTML = segments.map(([start, end]) => {
      const focused = state.focus && start === state.focus[0] && end === state.focus[1];
      let html = "";
      for (let i = start; i < end; i++) {
        if (i === caret) html += '<span class="caret"></span>';
        const marked = state.mark && i >= state.mark.range[0] && i < state.mark.range[1];
        html += marked ? `<span class="marked">${escapeHtml(text[i])}</span>` : escapeHtml(text[i]);
      }
      if (caret === end && end === text.length) html += '<span class="caret"></span>';
      return `<span class="seg${focused ? " focused" : ""}">${html}</span>`;
    }).join("") + (state.mark ? `<span class="hint">${{ add: "Enter 加入詞庫", remove: "Enter 從詞庫移除", tooShort: "至少 2 個字", tooLong: "最多 8 個字" }[state.mark.action] ?? ""}</span>` : "");
    const showList = state.showsCandidates && state.candidates?.length > 0;
    listEl.hidden = panel.querySelector(".foot").hidden = !showList;
    if (showList) {
      const keys = state.selectionKeys || [];
      prev.disabled = state.page === 0;
      next.disabled = state.page + 1 >= state.pageCount;
      pageEl.textContent = `${state.page + 1}/${state.pageCount}`;
      listEl.innerHTML = (state.pageCandidates || []).map((cand, i) =>
        `<div class="item${i === state.pageSelected ? " selected" : ""}" data-index="${state.page * state.pageSize + i}"><span>${escapeHtml(cand)}</span><span class="key">${state.keysActive ? escapeHtml((keys[i] || String(i + 1)).toUpperCase()) : ""}</span></div>`).join("");
    }
    panel.hidden = false;
    place(active ? caretBox(active) : null);
  }

  /** Delivers finished text to the field and redraws. */
  function sync(fromKey = false) {
    const text = ime.takeCommitted();
    state = ime.state();
    if (text && active) insertText(active, text);
    if (ime.userDictionaryCount() !== knownWords) {
      knownWords = ime.userDictionaryCount();
      writeStored(storageKey, ime.userDictionaryText());
    }
    if (ime.learningRevision() !== knownLearning) {
      knownLearning = ime.learningRevision();
      writeStored(learningKey, ime.learnedCount() ? ime.learnedData() : "");
      writeStored(slipsKey, ime.channelCount() ? ime.channelData() : "");
    }
    // As on desktop: opening or closing an English run inside a Chinese
    // composition (latinToggled) and a mode change both flash. The flags
    // describe the last key, so only a key event may read them.
    if (fromKey && active) {
      if (state.latinToggled) flash(state.latinActive, caretBox(active));
      if (state.modeChanged) flash(state.english, caretBox(active));
    }
    paint();
  }

  function flush() {
    if (state?.preedit && ime.commit()) sync();
  }

  function onKeyDown(e) {
    const el = targetOf(e);
    if (!el) return;
    if (active !== el) {
      flush();
      active = el;
    }
    if (e.isComposing || e.keyCode === 229) {
      nativeKeys += 1;
      if (nativeKeys === 2) options.onNativeIme?.(true);
      return;
    }
    if (nativeKeys) options.onNativeIme?.(false);
    nativeKeys = 0;
    const decoderCtrl = e.ctrlKey && !e.metaKey && (e.code === "KeyJ" || e.code === "KeyK");
    if (e.metaKey || (e.ctrlKey && !decoderCtrl) || e.code === "Home" || e.code === "End") {
      flush();
      return;
    }
    if (ime.key(e.code, e.key, modifierBits(e), 0)) {
      e.preventDefault();
      e.stopImmediatePropagation();
    }
    sync(true);
  }

  function onKeyUp(e) {
    if (!targetOf(e) || (e.code !== "ShiftLeft" && e.code !== "ShiftRight")) return;
    if (ime.key(e.code, e.key, modifierBits(e), 1)) e.preventDefault();
    sync(true);
  }

  const onPointerDown = (e) => { if (!e.composedPath().includes(host)) flush(); };
  const onFocusOut = (e) => { if (targetOf(e) && e.target === active) flush(); };
  const onCompositionStart = (e) => { if (targetOf(e)) flush(); };
  const onViewport = () => place(active ? caretBox(active) : null);

  // Taps on the window must not take focus from the field (that would end the composition).
  panel.addEventListener("pointerdown", (e) => e.preventDefault());
  listEl.addEventListener("click", (e) => {
    const item = e.target.closest(".item");
    if (!item) return;
    ime.pick(Number(item.dataset.index));
    sync();
    active?.focus();
  });
  for (const button of [prev, next]) button.addEventListener("click", () => {
    ime.key(button.dataset.page, button.dataset.page, 0, 0);
    sync();
    active?.focus();
  });

  document.addEventListener("keydown", onKeyDown, true);
  document.addEventListener("keyup", onKeyUp, true);
  document.addEventListener("pointerdown", onPointerDown, true);
  document.addEventListener("focusout", onFocusOut, true);
  document.addEventListener("compositionstart", onCompositionStart, true);
  addEventListener("resize", onViewport);
  addEventListener("scroll", onViewport, true);
  window.visualViewport?.addEventListener("resize", onViewport);

  sync();

  return {
    /** The low-level `MisstypeWasm` instance, for anything this layer does not cover. */
    ime,
    /** Switches between Chinese and English mode (a lone Shift tap does the same). */
    toggleEnglish() {
      ime.toggleEnglish();
      sync();
      if (active) flash(state.english, caretBox(active));
    },
    /** What has been learned: `{ phrases: [{ reading, text, count, updatedAt }], slips: [{ typed, intended, cost }] }`. */
    learned() {
      return { phrases: ime.learnedPhrases(), slips: ime.channelPairs() };
    },
    /** Forgets one learned phrase (`reading` as listed by `learned()`). */
    forgetLearned(reading, text) {
      ime.forgetLearned(reading, text);
      sync();
    },
    /** Forgets every learned phrase. */
    clearLearned() {
      ime.clearLearned();
      sync();
    },
    /** Forgets every learned typing slip. */
    clearSlips() {
      ime.clearChannel();
      sync();
    },
    /** Changes a decoder setting (`pageSize`, `shiftToggle`, `returnConfirmsSelection`, `autoShowCandidates`,
     *  `userLearning`, `channelLearning`). */
    setSetting(name, value) {
      settings[name] = value;
      ime.setSetting(name, value);
      sync();
    },
    setLayout(value) {
      layout = value;
      panel.classList.toggle("horizontal", value === "horizontal");
    },
    /** Commits whatever is being composed. */
    flush,
    /** Removes every listener and the candidate window. The decoder instance is dropped with it. */
    destroy() {
      flush();
      document.removeEventListener("keydown", onKeyDown, true);
      document.removeEventListener("keyup", onKeyUp, true);
      document.removeEventListener("pointerdown", onPointerDown, true);
      document.removeEventListener("focusout", onFocusOut, true);
      document.removeEventListener("compositionstart", onCompositionStart, true);
      removeEventListener("resize", onViewport);
      removeEventListener("scroll", onViewport, true);
      window.visualViewport?.removeEventListener("resize", onViewport);
      scheme.removeEventListener?.("change", paintScheme);
      host.remove();
    },
  };
}

export default enable;
