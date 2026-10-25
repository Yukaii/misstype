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

test("learning: an explicit pick is learned, saved, restored, forgotten, and can be turned off", async () => {
  const load = () => MisstypeWasm.load({
    wasmUrl: `data:application/wasm;base64,${wasm.toString("base64")}`,
    lexiconUrl: `data:text/plain;base64,${lexicon.toString("base64")}`,
  });
  const typeAndPick = (ime) => {
    ime.setSetting("autoShowCandidates", true);
    for (const key of "su3") ime.key(/[0-9]/.test(key) ? `Digit${key}` : `Key${key.toUpperCase()}`, key);
    assert.equal(ime.state().preedit, "你");
    ime.pick(1);
    ime.commit();
    return ime.takeCommitted();
  };

  const ime = await load();
  assert.equal(ime.learnedCount(), 0);
  const before = ime.learningRevision();
  assert.equal(typeAndPick(ime), "妳");
  assert.equal(ime.learnedCount(), 1);
  assert.notEqual(ime.learningRevision(), before);
  const [phrase] = ime.learnedPhrases();
  assert.equal(phrase.text, "妳");
  assert.equal(phrase.reading, "ㄋㄧ");
  assert.equal(phrase.count, 1);

  // A fresh module restores it from the saved JSON and ranks it first.
  const data = ime.learnedData();
  const restored = await load();
  assert.equal(restored.loadLearned("not json"), false);
  assert.equal(restored.learnedCount(), 0);
  assert.equal(restored.loadLearned(data), true);
  assert.equal(restored.learnedCount(), 1);
  restored.setSetting("autoShowCandidates", true);
  for (const key of "su3") restored.key(/[0-9]/.test(key) ? `Digit${key}` : `Key${key.toUpperCase()}`, key);
  assert.equal(restored.state().preedit, "妳");

  restored.forgetLearned(phrase.reading, phrase.text);
  assert.equal(restored.learnedCount(), 0);
  assert.equal(ime.loadLearned(data), true);
  ime.clearLearned();
  assert.equal(ime.learnedCount(), 0);

  const off = await load();
  off.setSetting("userLearning", false);
  typeAndPick(off);
  assert.equal(off.learnedCount(), 0);
});

test("typing slips: empty by default, round-trips, and clears", async () => {
  const ime = await MisstypeWasm.load({
    wasmUrl: `data:application/wasm;base64,${wasm.toString("base64")}`,
    lexiconUrl: `data:text/plain;base64,${lexicon.toString("base64")}`,
  });
  assert.equal(ime.channelCount(), 0);
  assert.deepEqual(ime.channelPairs(), []);
  assert.equal(ime.loadChannel("nope"), false);
  assert.equal(ime.loadChannel(ime.channelData()), true);
  ime.clearChannel();
  assert.equal(ime.channelCount(), 0);
  ime.setSetting("channelLearning", true);
});


test("sparse model loads only on request, owns its bytes, and malformed assets fall back", async () => {
  const toyLex = "ㄋㄧˇ\t你\t-5\nㄋㄧˇ\t妳\t-6\n";
  const fixture = [77,83,76,77,1,0,0,0,5,0,0,0,1,0,0,0,20,0,0,0,0,0,0,0,0,0,0,0,0,0,232,63,211,237,100,102,27,62,30,26,85,85,213,62,0,0,128,63,94,83,145,103,27,232,98,30,171,170,170,61,0,0,128,63,18,76,227,47,24,138,212,111,0,0,0,0,51,51,51,62,153,234,39,212,26,1,212,123,171,170,234,62,0,0,128,63,225,185,111,214,77,224,1,230,171,170,42,61,0,0,128,63,2,0,0,0,0,0,0,0,51,51,83,63];
  const sparse = new Uint8Array(fixture);
  const options = {
    wasmUrl: `data:application/wasm;base64,${wasm.toString("base64")}`,
    lexiconUrl: `data:text/plain;base64,${Buffer.from(toyLex).toString("base64")}`,
  };
  const type = (ime) => { for (const key of "su3") ime.key(/[0-9]/.test(key) ? `Digit${key}` : `Key${key.toUpperCase()}`, key); };
  const baseline = await MisstypeWasm.load(options);
  type(baseline);
  assert.equal(baseline.wordModelLoaded, false);
  assert.equal(baseline.state().preedit, "你");
  assert.equal(baseline.loadWordModel(sparse, NaN), false);
  assert.equal(baseline.loadWordModel(sparse, .5), true);
  sparse.fill(0); // upload freed and source changed; decoder's copy still works
  baseline.reset(); type(baseline);
  assert.equal(baseline.state().preedit, "妳");
  assert.equal(baseline.loadWordModel(new Uint8Array(fixture), .5), false, "repeated loads don't accumulate arena copies");
  const fallback = await MisstypeWasm.load({ ...options, wordModelUrl: "data:application/octet-stream;base64,TUZMTQ==" });
  type(fallback);
  assert.equal(fallback.wordModelLoaded, false);
  assert.equal(fallback.state().preedit, "你");
  const loaded = await MisstypeWasm.load({ ...options,
    wordModelUrl: `data:application/octet-stream;base64,${Buffer.from(fixture).toString("base64")}` });
  type(loaded);
  assert.equal(loaded.wordModelLoaded, true);
  assert.equal(loaded.state().preedit, "妳");
});

test("fromBytes loads in-memory assets like load does", async () => {
  const ime = await MisstypeWasm.fromBytes({ wasm, lexicon: lexicon.toString("utf8") });
  for (const key of "su3cl3") {
    const code = /[0-9]/.test(key) ? `Digit${key}` : `Key${key.toUpperCase()}`;
    ime.key(code, key);
  }
  assert.equal(ime.state().preedit, "你好");
  await assert.rejects(MisstypeWasm.fromBytes({ wasm }), TypeError);
});
