import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";
import MisstypeWasm from "../src/index.js";

const root = new URL("../../../", import.meta.url);
const wasm = await readFile(new URL("core-zig/zig-out/wasm/misstype.wasm", root));
const lexicon = await readFile(new URL("tests/fixtures/lexicon/lexicon.tsv", root));

test("packaged wrapper loads assets, preserves page size, and drains commits once", async () => {
  const ime = await MisstypeWasm.load({
    wasmUrl: `data:application/wasm;base64,${wasm.toString("base64")}`,
    lexiconUrl: `data:text/plain;base64,${lexicon.toString("base64")}`,
  });
  ime.setSetting("pageSize", 6);
  ime.setSetting("autoShowCandidates", true);
  for (const key of "su3cl3") {
    const code = /[0-9]/.test(key) ? `Digit${key}` : `Key${key.toUpperCase()}`;
    assert.equal(ime.key(code, key), true);
  }
  assert.equal(ime.state().preedit, "你好");
  assert.equal(ime.state().pageSize, 6);
  assert.equal(ime.state().showsCandidates, true);
  assert.equal(ime.commit(), true);
  assert.equal(ime.takeCommitted(), "你好");
  assert.equal(ime.takeCommitted(), "");
  assert.equal(ime.state().preedit, "");
  assert.equal(ime.setEnglish(true), true);
  assert.equal(ime.key("KeyA", "a"), false);
  assert.equal(ime.toggleEnglish(), false);
  ime.reset();
  assert.equal(ime.state().preedit, "");
});

test("user dictionary: set, check, import, and the decoder uses added words", async () => {
  const ime = await MisstypeWasm.load({
    wasmUrl: `data:application/wasm;base64,${wasm.toString("base64")}`,
    lexiconUrl: `data:text/plain;base64,${lexicon.toString("base64")}`,
  });
  assert.equal(ime.userDictionaryCount(), 0);
  const text = "# mine\n隨打注音 ㄙㄨㄟˊ-ㄉㄚˇ-ㄓㄨˋ-ㄧㄣ\nnot a line\n";
  const check = ime.checkUserDictionary(text);
  assert.equal(check.added, 1);
  assert.equal(check.hidden, 0);
  assert.equal(check.problems.length, 1);
  assert.equal(check.problems[0].line, 3);
  assert.equal(ime.setUserDictionary(text), true);
  assert.equal(ime.userDictionaryCount(), 1);
  assert.match(ime.userDictionaryText(), /隨打注音 ㄙㄨㄟˊ-ㄉㄚˇ-ㄓㄨˋ-ㄧㄣ/);
  const merged = ime.importUserDictionary("隨打注音 ㄙㄨㄟˊ-ㄉㄚˇ-ㄓㄨˋ-ㄧㄣ\n你好嗎 ㄋㄧˇ-ㄏㄠˇ-ㄇㄚ\n", ime.userDictionaryText());
  assert.equal(merged.added, 1);
  assert.equal(merged.duplicates, 1);
  assert.match(merged.text, /你好嗎 ㄋㄧˇ-ㄏㄠˇ-ㄇㄚ/);
  assert.equal(ime.userDictionaryCount(), 1, "import only edits text until it is set");
  assert.equal(ime.setUserDictionary(""), true);
  assert.equal(ime.userDictionaryCount(), 0);
});
