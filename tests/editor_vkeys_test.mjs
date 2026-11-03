// Checks the on-screen keyboard layout (site/editor/vkeys.js): every Zhuyin
// symbol is on exactly one key, codes are unique, and Shift swaps Zhuyin for Latin.
//   cd site && npm ci && node ../tests/editor_vkeys_test.mjs
import assert from "node:assert/strict";
import test from "node:test";
import { INDENT, ROWS, capLabels, keyText } from "../site/editor/vkeys.js";

const keys = ROWS.flat();
const byCode = new Map(keys.map((k) => [k.code, k]));

test("key codes are unique and cover digits, letters and Zhuyin punctuation", () => {
  assert.equal(byCode.size, keys.length);
  for (const code of [..."0123456789"].map((d) => `Digit${d}`)) assert.ok(byCode.has(code), code);
  for (const c of "ABCDEFGHIJKLMNOPQRSTUVWXYZ") assert.ok(byCode.has(`Key${c}`), c);
  for (const code of ["Minus", "Comma", "Period", "Slash", "Semicolon", "Space", "Enter", "Backspace", "ShiftLeft"]) {
    assert.ok(byCode.has(code), code);
  }
});

test("all 37 Zhuyin symbols and 5 tone marks appear exactly once", () => {
  const symbols = keys.map((k) => k.zhuyin).filter(Boolean).sort();
  const expected = [..."ㄅㄆㄇㄈㄉㄊㄋㄌㄍㄎㄏㄐㄑㄒㄓㄔㄕㄖㄗㄘㄙㄧㄨㄩㄚㄛㄜㄝㄞㄟㄠㄡㄢㄣㄤㄥㄦ", "ˇ", "ˋ", "ˊ", "˙"].sort();
  assert.deepEqual(symbols, expected);
});

test("rows match the iOS Zhuyin keyboard", () => {
  const zhuyin = (r) => r.map((k) => k.zhuyin ?? k.special).join("");
  assert.deepEqual(ROWS.map((r) => r.length), [11, 10, 10, 11, 5]);
  assert.equal(INDENT.length, ROWS.length);
  assert.equal(zhuyin(ROWS[0]), "ㄅㄉˇˋㄓˊ˙ㄚㄞㄢㄦ");
  assert.equal(zhuyin(ROWS[1]), "ㄆㄊㄍㄐㄔㄗㄧㄛㄟㄣ");
  assert.equal(zhuyin(ROWS[2]), "ㄇㄋㄎㄑㄕㄘㄨㄜㄠㄤ");
  assert.equal(zhuyin(ROWS[3]), "ㄈㄌㄏㄒㄖㄙㄩㄝㄡㄥbackspace");
});

test("Zhuyin leads in Chinese mode; Shift or English shows Latin", () => {
  const a = byCode.get("KeyA");
  assert.deepEqual(capLabels(a), ["ㄇ", "a"]);
  assert.deepEqual(capLabels(a, { shift: true }), ["A", ""]);
  assert.deepEqual(capLabels(a, { english: true }), ["a", ""]);
  assert.deepEqual(capLabels(byCode.get("Digit1"), { shift: true, english: true }), ["!", ""]);
  assert.deepEqual(capLabels(byCode.get("Space")), ["空白", ""]);
});

test("key text matches what a US keyboard reports", () => {
  assert.equal(keyText(byCode.get("KeyQ")), "q");
  assert.equal(keyText(byCode.get("KeyQ"), true), "Q");
  assert.equal(keyText(byCode.get("Digit2"), true), "@");
  assert.equal(keyText(byCode.get("Slash"), true), "?");
  assert.equal(keyText(byCode.get("Space")), " ");
  assert.equal(keyText(byCode.get("Enter")), "Enter");
});

test("Shift in Chinese mode shows the full-width mark the decoder types", () => {
  assert.deepEqual(capLabels(byCode.get("Digit1"), { shift: true }), ["！", ""]);
  assert.deepEqual(capLabels(byCode.get("Comma"), { shift: true }), ["，", ""]);
  assert.deepEqual(capLabels(byCode.get("Slash"), { shift: true }), ["？", ""]);
  assert.deepEqual(capLabels(byCode.get("Comma"), { shift: true, english: true }), ["<", ""]);
});

test("the ，。 keys send Shift + the physical key in Chinese, the bare key in English", () => {
  const comma = byCode.get("PunctComma");
  const period = byCode.get("PunctPeriod");
  assert.equal(comma.sends, "Comma");
  assert.equal(period.sends, "Period");
  assert.deepEqual(capLabels(comma), ["，", ""]);
  assert.deepEqual(capLabels(comma, { english: true }), [",", ""]);
  assert.equal(keyText(comma, true), "<");
  assert.equal(keyText(comma, false, true), ",");
  assert.deepEqual(capLabels(period), ["。", ""]);
  assert.equal(keyText(period, false, true), ".");
  assert.deepEqual(ROWS[4].map((k) => k.special), ["shift", "punct", "space", "punct", "enter"]);
});
