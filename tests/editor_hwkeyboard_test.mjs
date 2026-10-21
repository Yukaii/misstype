// Checks hardware-keyboard detection for the on-screen keyboard
// (site/editor/keyboard.js fromHardwareKeyboard): system-keyboard typing in a
// text field must not count, or the on-screen keyboard never comes back.
//   cd site && npm ci && node ../tests/editor_hwkeyboard_test.mjs
import assert from "node:assert/strict";
import test from "node:test";
import { fromHardwareKeyboard } from "../site/editor/keyboard.js";

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
