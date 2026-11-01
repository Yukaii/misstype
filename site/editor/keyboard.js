// On-screen Zhuyin keyboard (iOS layout), for touch devices that have no
// physical keyboard. It only draws keys and reports presses; editor.js feeds
// them through the same keydown path as a hardware keyboard, so the decoder,
// settings and fall-through to ProseMirror behave identically.
import { INDENT, ROWS, capLabels, keyText } from "./vkeys.js";

/**
 * Whether a keydown proves a hardware keyboard. The system keyboard also sends
 * real keydowns (Latin letters, Backspace, Return) while it types into a text
 * field (note rename, palette, dictionary), so only keys aimed at the editor,
 * where inputmode="none" keeps the system keyboard away, or at nothing focused count.
 * @param {KeyboardEvent} e
 * @param {HTMLElement} editor
 */
export function fromHardwareKeyboard(e, editor) {
  if (!e.isTrusted || e.isComposing || e.keyCode === 229 || e.key === "Unidentified") return false;
  return e.target === e.target?.ownerDocument?.body || editor.contains(e.target);
}

/**
 * Whether the on-screen keyboard is wanted, before the chevron's dismissal.
 * `on` and `off` are the user's explicit choice; `auto` is the best guess a
 * page can make (a touch device that has not shown a hardware key yet).
 * @param {string} mode  settings.virtualKeyboard: "auto" | "on" | "off"
 * @param {boolean} touch  a touch-only device (auto's pointer/hover query)
 * @param {boolean} hardwareKeyboardSeen  a real key was typed since "auto"
 */
export function virtualKeyboardWanted(mode, touch, hardwareKeyboardSeen) {
  return mode === "on" || (mode === "auto" && touch && !hardwareKeyboardSeen);
}

/** Whether to paint the keyboard now: wanted, and not dismissed with the chevron. */
export function virtualKeyboardVisible(mode, touch, hardwareKeyboardSeen, dismissed) {
  return virtualKeyboardWanted(mode, touch, hardwareKeyboardSeen) && !dismissed;
}

/**
 * How far a key label must move to sit on the key's optical centre, in em.
 * A font's ascent/descent box is not symmetric around the glyph ink, so
 * centring the line box leaves the glyph high (or low). Measured at start-up
 * because the system font differs between iOS, Android and desktop.
 * @param {{ascent:number, descent:number, inkAscent:number, inkDescent:number}} metrics
 * @param {number} fontSize  px
 */
export function labelShiftEm(metrics, fontSize) {
  const { ascent, descent, inkAscent, inkDescent } = metrics;
  if (![ascent, descent, inkAscent, inkDescent, fontSize].every(Number.isFinite) || fontSize <= 0) return 0;
  const shift = ((inkAscent - inkDescent) - (ascent - descent)) / (2 * fontSize);
  return Math.max(-0.15, Math.min(0.15, shift));
}

const REPEAT_DELAY = 420;
const REPEAT_EVERY = 55;

// iOS-style action icons. Font glyphs (⇧ ⌫) sat thin and off-centre in the
// system font, and the delete-left shape differs between platforms.
const ICONS = {
  shift: '<svg viewBox="0 0 16 16" aria-hidden="true"><path d="M8 2.9 12.8 8.4h-2.6v4.2H5.8V8.4H3.2z"/></svg>',
  backspace: '<svg viewBox="0 0 16 16" aria-hidden="true"><path d="M5.2 3.2h9.4v9.6H5.2L1.2 8z"/><path d="m7.6 6.1 3.5 3.8M11.1 6.1 7.6 9.9"/></svg>',
};

function ariaLabel(key, shift) {
  if (key.special === "shift") return "Shift";
  if (key.special === "backspace") return "刪除";
  return key.special ? key.label : keyText(key, shift);
}

/**
 * @param {HTMLElement} el  container (hidden until `show`)
 * @param {{ press(key, text, shift): void, shift(down: boolean): void }} handlers
 */
export class VirtualKeyboard {
  constructor(el, handlers) {
    this.el = el;
    this.handlers = handlers;
    this.shiftHeld = new Set(); // pointer ids currently holding Shift
    this.english = false;
    this.caps = new Map(); // key code -> [main, hint] elements
    this.timers = new Map(); // pointer id -> repeat timers
    this.build();
    this.alignCaps();
    document.fonts?.ready.then(() => this.alignCaps());
    el.addEventListener("pointerdown", (e) => this.down(e));
    el.addEventListener("pointerup", (e) => this.up(e));
    el.addEventListener("pointercancel", (e) => this.up(e));
    el.addEventListener("contextmenu", (e) => e.preventDefault());
    // iOS ignores preventDefault on pointerdown for focus; these keep the editor focused.
    for (const type of ["touchstart", "mousedown"]) el.addEventListener(type, (e) => e.preventDefault(), { passive: false });
  }

  build() {
    this.el.textContent = "";
    ROWS.forEach((keys, i) => {
      const rowEl = document.createElement("div");
      rowEl.className = "vk-row";
      rowEl.style.setProperty("--vk-indent", String(INDENT[i] ?? 0));
      for (const key of keys) {
        const b = document.createElement("button");
        b.type = "button";
        b.className = "vk-key";
        b.dataset.code = key.code;
        if (key.special) b.dataset.special = key.special;
        if (ICONS[key.special]) b.dataset.icon = "";
        b.tabIndex = -1;
        if (key.fill) b.style.flex = "1 1 0";
        else if (key.wide) b.style.setProperty("--vk-span", String(key.wide));
        const main = document.createElement("span");
        main.className = "vk-main";
        const hint = document.createElement("span");
        hint.className = "vk-hint";
        hint.setAttribute("aria-hidden", "true");
        b.append(main, hint);
        this.caps.set(key.code, { key, main, hint, button: b });
        rowEl.append(b);
      }
      this.el.append(rowEl);
    });
    this.render();
  }

  /**
   * Measures the label font once (ㄅ is a full-height glyph) and stores the
   * ink-versus-line-box offset for CSS. The canvas is never attached; this only
   * reads metrics, and re-runs when webfonts settle.
   */
  alignCaps() {
    const main = this.caps.get("Digit1")?.main;
    if (!main?.isConnected) return;
    const style = getComputedStyle(main);
    const ctx = document.createElement("canvas").getContext("2d");
    if (!ctx) return;
    ctx.font = `${style.fontSize} ${style.fontFamily}`;
    const m = ctx.measureText("ㄅ");
    const shift = labelShiftEm({
      ascent: m.fontBoundingBoxAscent,
      descent: m.fontBoundingBoxDescent,
      inkAscent: m.actualBoundingBoxAscent,
      inkDescent: m.actualBoundingBoxDescent,
    }, parseFloat(style.fontSize));
    this.el.style.setProperty("--vk-label-shift", `${shift}em`);
  }

  get shift() { return this.shiftHeld.size > 0; }

  /** Switches the caps between Zhuyin and Latin when the decoder's mode changes. */
  setEnglish(english) {
    if (english === this.english) return;
    this.english = english;
    this.render();
  }

  render() {
    const state = { shift: this.shift, english: this.english };
    this.el.dataset.shift = String(this.shift);
    for (const { key, main, hint, button } of this.caps.values()) {
      const [m, h] = capLabels(key, state);
      const icon = ICONS[key.special];
      if (icon) main.innerHTML = icon;
      else main.textContent = m;
      hint.textContent = h;
      button.dataset.preview = m;
      button.setAttribute("aria-label", ariaLabel(key, this.shift));
    }
  }

  codeOf(e) {
    return e.target.closest?.(".vk-key")?.dataset.code;
  }

  down(e) {
    const code = this.codeOf(e);
    if (!code) return;
    // Keep focus (and the composition) in the editor.
    e.preventDefault();
    const { key, button } = this.caps.get(code);
    button.setPointerCapture?.(e.pointerId);
    button.classList.add("down");
    button.dataset.pointer = String(e.pointerId);
    if (key.special === "shift") {
      this.shiftHeld.add(e.pointerId);
      this.render();
      this.handlers.shift(true);
      return;
    }
    this.fire(key);
    if (key.repeat) {
      const start = setTimeout(() => {
        const every = setInterval(() => this.fire(key), REPEAT_EVERY);
        this.timers.set(e.pointerId, { every });
      }, REPEAT_DELAY);
      this.timers.set(e.pointerId, { start });
    }
  }

  up(e) {
    const timers = this.timers.get(e.pointerId);
    if (timers) {
      clearTimeout(timers.start);
      clearInterval(timers.every);
      this.timers.delete(e.pointerId);
    }
    for (const { button, key } of this.caps.values()) {
      if (button.dataset.pointer !== String(e.pointerId)) continue;
      delete button.dataset.pointer;
      button.classList.remove("down");
      if (key.special === "shift" && this.shiftHeld.delete(e.pointerId)) {
        this.render();
        this.handlers.shift(false);
      }
    }
  }

  fire(key) {
    this.handlers.press(key.code, keyText(key, this.shift), this.shift);
  }
}
