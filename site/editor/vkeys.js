// Layout of the on-screen keyboard (Dachen / standard Zhuyin on a QWERTY grid).
// Data only, so tests/editor_vkeys_test.mjs can check it without a DOM.
//
// Each key is sent to the decoder as the physical key it stands for: `code`
// is the DOM KeyboardEvent.code, and the text is the US-ANSI character, upper
// or shifted while Shift is held. The decoder does the rest, exactly as for a
// hardware keyboard.

const row = (spec) => spec.map(([code, lower, zhuyin, upper]) => ({
  code, lower, zhuyin, upper: upper ?? lower.toUpperCase(),
}));

export const ROWS = [
  row([
    ["Digit1", "1", "ㄅ", "!"], ["Digit2", "2", "ㄉ", "@"], ["Digit3", "3", "ˇ", "#"], ["Digit4", "4", "ˋ", "$"],
    ["Digit5", "5", "ㄓ", "%"], ["Digit6", "6", "ˊ", "^"], ["Digit7", "7", "˙", "&"], ["Digit8", "8", "ㄚ", "*"],
    ["Digit9", "9", "ㄞ", "("], ["Digit0", "0", "ㄢ", ")"],
  ]),
  row([
    ["KeyQ", "q", "ㄆ"], ["KeyW", "w", "ㄊ"], ["KeyE", "e", "ㄍ"], ["KeyR", "r", "ㄐ"], ["KeyT", "t", "ㄔ"],
    ["KeyY", "y", "ㄗ"], ["KeyU", "u", "ㄧ"], ["KeyI", "i", "ㄛ"], ["KeyO", "o", "ㄟ"], ["KeyP", "p", "ㄣ"],
  ]),
  row([
    ["KeyA", "a", "ㄇ"], ["KeyS", "s", "ㄋ"], ["KeyD", "d", "ㄎ"], ["KeyF", "f", "ㄑ"], ["KeyG", "g", "ㄕ"],
    ["KeyH", "h", "ㄘ"], ["KeyJ", "j", "ㄨ"], ["KeyK", "k", "ㄜ"], ["KeyL", "l", "ㄠ"], ["Semicolon", ";", "ㄤ", ":"],
  ]),
  [
    { code: "ShiftLeft", special: "shift", label: "⇧", wide: 1.4 },
    ...row([
      ["KeyZ", "z", "ㄈ"], ["KeyX", "x", "ㄌ"], ["KeyC", "c", "ㄏ"], ["KeyV", "v", "ㄒ"], ["KeyB", "b", "ㄖ"],
      ["KeyN", "n", "ㄙ"], ["KeyM", "m", "ㄩ"],
    ]),
    { code: "Backspace", special: "backspace", label: "⌫", wide: 1.4, repeat: true },
  ],
  [
    ...row([["Minus", "-", "ㄦ", "_"], ["Comma", ",", "ㄝ", "<"]]),
    { code: "Space", special: "space", label: "空白", text: " ", wide: 4 },
    ...row([["Period", ".", "ㄡ", ">"], ["Slash", "/", "ㄥ", "?"]]),
    { code: "Enter", special: "enter", label: "換行", wide: 1.6 },
  ],
];

/** What the key prints on its cap: [main, hint]. Chinese mode leads with Zhuyin; Shift or English shows Latin. */
export function capLabels(key, { shift = false, english = false } = {}) {
  if (key.special) return [key.label, ""];
  const latin = shift ? key.upper : key.lower;
  if (shift || english || !key.zhuyin) return [latin, ""];
  return [key.zhuyin, key.lower];
}

/** The KeyboardEvent.key a physical keyboard would produce for this key. */
export function keyText(key, shift = false) {
  switch (key.special) {
    case "shift": return "Shift";
    case "backspace": return "Backspace";
    case "enter": return "Enter";
    case "space": return " ";
    default: return shift ? key.upper : key.lower;
  }
}
