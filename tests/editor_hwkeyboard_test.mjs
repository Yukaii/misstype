// Checks hardware-keyboard detection (site/editor/keyboard.js
// fromHardwareKeyboard) and the on-screen keyboard visibility matrix: typing
// in a text field must not hide it, and the manual switch must win.
//   cd site && npm ci && node ../tests/editor_hwkeyboard_test.mjs
import assert from "node:assert/strict";
import test from "node:test";
import { fromHardwareKeyboard, labelShiftEm, systemKeyboardSuppressed, virtualKeyboardVisible, virtualKeyboardWanted } from "../site/editor/keyboard.js";

const body = {};
const doc = { body };
const node = (inEditor) => ({ ownerDocument: doc, inEditor });
const editor = { contains: (t) => !!t?.inEditor };
const key = (target, extra = {}) => ({ isTrusted: true, isComposing: false, keyCode: 65, key: "a", target, ...extra });
body.ownerDocument = doc;

test("a real key in the editor counts", () => {
  assert.equal(fromHardwareKeyboard(key(node(true)), editor), true);
  assert.equal(fromHardwareKeyboard(key(node(true), { key: "Backspace", keyCode: 8 }), editor), true);
});

test("a real key with nothing focused counts", () => {
  assert.equal(fromHardwareKeyboard(key(body), editor), true);
});

test("system-keyboard typing in a text field (rename, palette) does not", () => {
  const field = node(false);
  assert.equal(fromHardwareKeyboard(key(field), editor), false);
  assert.equal(fromHardwareKeyboard(key(field, { key: "Enter", keyCode: 13 }), editor), false);
});

test("IME, synthetic and unidentified keys never count", () => {
  const target = node(true);
  assert.equal(fromHardwareKeyboard(key(target, { isTrusted: false }), editor), false);
  assert.equal(fromHardwareKeyboard(key(target, { isComposing: true }), editor), false);
  assert.equal(fromHardwareKeyboard(key(target, { keyCode: 229 }), editor), false);
  assert.equal(fromHardwareKeyboard(key(target, { key: "Unidentified" }), editor), false);
});

test("auto shows the keyboard on a touch device until a real key is seen", () => {
  assert.equal(virtualKeyboardVisible("auto", true, false, false), true);
  assert.equal(virtualKeyboardVisible("auto", true, true, false), false);
  assert.equal(virtualKeyboardVisible("auto", false, false, false), false);
  assert.equal(virtualKeyboardWanted("auto", true, false), true);
  assert.equal(virtualKeyboardWanted("auto", true, true), false);
});

test("always and off ignore what the device looks like", () => {
  assert.equal(virtualKeyboardVisible("on", false, true, false), true);
  assert.equal(virtualKeyboardVisible("on", false, false, false), true);
  assert.equal(virtualKeyboardVisible("off", true, false, false), false);
  assert.equal(virtualKeyboardVisible("off", true, true, false), false);
});

test("the chevron hides even an explicitly requested keyboard", () => {
  assert.equal(virtualKeyboardVisible("on", true, false, true), false);
  assert.equal(virtualKeyboardVisible("auto", true, false, true), false);
  // A hidden chevron keyboard still suppresses the system keyboard.
  assert.equal(virtualKeyboardWanted("on", true, false), true);
});

test("a hardware keyboard keeps the system IME away with the on-screen one off", () => {
  // iPad + Magic Keyboard after the 鍵盤 switch: the decoder still owns keys.
  assert.equal(systemKeyboardSuppressed("off", true, true), true);
  assert.equal(systemKeyboardSuppressed("auto", true, true), true);
  // No hardware keyboard: off is the explicit choice to use the system one.
  assert.equal(systemKeyboardSuppressed("off", true, false), false);
  // A shown keyboard always suppresses the system one, even on a desktop.
  assert.equal(systemKeyboardSuppressed("on", false, false), true);
  // Auto on a desktop or phone keeps the old behaviour.
  assert.equal(systemKeyboardSuppressed("auto", false, false), false);
});

test("key labels are nudged by the font's ink offset, not a fixed amount", () => {
  // Measured for Noto Sans CJK at 18px: font box 16/5, ㄅ ink 16/2.
  assert.equal(labelShiftEm({ ascent: 16, descent: 5, inkAscent: 16, inkDescent: 2 }, 18).toFixed(4), "0.0833");
  // Symmetric ink relative to the font box needs no nudge.
  assert.equal(labelShiftEm({ ascent: 16, descent: 5, inkAscent: 15, inkDescent: 4 }, 18), 0);
  assert.equal(labelShiftEm({}, 18), 0);
  // Absurd metrics are clamped to a small correction.
  assert.equal(labelShiftEm({ ascent: 0, descent: 0, inkAscent: 100, inkDescent: 0 }, 10), 0.15);
});
