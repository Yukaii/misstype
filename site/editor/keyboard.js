// On-screen mini QWERTY with a number row, for touch devices that have no
// physical keyboard. It only draws keys and reports presses; editor.js feeds
// them through the same keydown path as a hardware keyboard, so the decoder,
// settings and fall-through to ProseMirror behave identically.
import { ROWS, capLabels, keyText } from "./vkeys.js";

const REPEAT_DELAY = 420;
const REPEAT_EVERY = 55;

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
    el.addEventListener("pointerdown", (e) => this.down(e));
    el.addEventListener("pointerup", (e) => this.up(e));
    el.addEventListener("pointercancel", (e) => this.up(e));
    el.addEventListener("contextmenu", (e) => e.preventDefault());
    // iOS ignores preventDefault on pointerdown for focus; these keep the editor focused.
    for (const type of ["touchstart", "mousedown"]) el.addEventListener(type, (e) => e.preventDefault(), { passive: false });
  }

  build() {
    this.el.textContent = "";
    for (const keys of ROWS) {
      const rowEl = document.createElement("div");
      rowEl.className = "vk-row";
      for (const key of keys) {
        const b = document.createElement("button");
        b.type = "button";
        b.className = "vk-key";
        b.dataset.code = key.code;
        if (key.special) b.dataset.special = key.special;
        b.tabIndex = -1;
        b.style.flexGrow = String(key.wide ?? 1);
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
    }
    this.render();
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
      main.textContent = m;
      hint.textContent = h;
      button.dataset.preview = m;
      button.setAttribute("aria-label", key.special ? key.label : keyText(key, this.shift));
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
