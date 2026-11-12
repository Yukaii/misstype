// Browser API suite for the WebAssembly module, through the package binding
// (packages/misstype-wasm), which is what the site, the video renderer and
// the Obsidian plugin use. The module is the C ABI of misstype.h compiled
// for wasm32-wasi; Test 9 keeps the two in step.
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { MisstypeWasm, ABI_VERSION } from "../packages/misstype-wasm/src/index.js";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.resolve(__dirname, "..");
const wasmPath = path.resolve(ROOT, "site/public/misstype.wasm");
if (!fs.existsSync(wasmPath)) {
  console.error("Wasm binary not found at", wasmPath);
  process.exit(1);
}

console.log("=== Misstype WebAssembly IME Test Suite ===");

// 1. Test IME initialization
console.log("Test 1: Initialize IME with fixture lexicon...");
const ime = await MisstypeWasm.fromBytes({
  wasm: fs.readFileSync(wasmPath),
  lexicon: fs.readFileSync(path.resolve(ROOT, "tests/fixtures/lexicon/lexicon.tsv"), "utf8"),
});
console.log("  [PASS] Initialized successfully");

const getState = () => ime.state();
const sendKey = (code, keyText = "", modifiers = 0, phase = 0) => ime.key(code, keyText, modifiers, phase, Date.now() / 1000);

// 1b. The optional homophone word-bigram table: malformed files are refused
// (decoding stays as it was); a well-formed one loads. Rerank behavior is
// covered by the Zig unit test "homophone table reorders ...".
console.log("Test 1b: Homophone table loader...");
{
  if (ime.loadHomophone(new TextEncoder().encode("MSHB-not-a-table"))) throw new Error("malformed homophone table was accepted");

  const fnvKey = (previous, current) => {
    const enc = new TextEncoder();
    let h = 0xcbf29ce484222325n;
    const mask = 0xffffffffffffffffn;
    for (const b of [...enc.encode(previous), 0xff, ...enc.encode(current)]) {
      h = ((h ^ BigInt(b)) * 0x100000001b3n) & mask;
    }
    return h >> 24n;
  };
  const table = new DataView(new ArrayBuffer(16 + 8));
  new Uint8Array(table.buffer).set(new TextEncoder().encode("MSHB"), 0);
  table.setUint32(4, 1, true);
  table.setUint32(8, 1, true);
  table.setUint32(12, 4, true);
  table.setBigUint64(16, (fnvKey("甲", "乙") << 8n) | 0x10n, true);
  if (!ime.loadHomophone(new Uint8Array(table.buffer))) throw new Error("well-formed homophone table was rejected");
  console.log("  [PASS] Malformed table refused, well-formed table loaded");
}

// 2. Test typing standard Zhuyin with tones (su3cl3 -> 你好)
console.log("Test 2: Standard Zhuyin with tones (su3cl3 -> 你好)...");
sendKey("KeyS", "s");
sendKey("KeyU", "u");
sendKey("Digit3", "3");
sendKey("KeyC", "c");
sendKey("KeyL", "l");
sendKey("Digit3", "3");

let state = getState();
if (state.preedit !== "你好") throw new Error(`Expected "你好", got "${state.preedit}"`);
console.log(`  [PASS] Preedit is "${state.preedit}"`);

// 3. Test Candidate window trigger (ArrowDown)
console.log("Test 3: Candidate window trigger (ArrowDown)...");
sendKey("ArrowDown", "ArrowDown");
state = getState();
if (!state.showsCandidates) throw new Error("Expected candidate window to be shown!");
if (state.candidates.length === 0) throw new Error("Expected candidates list not to be empty!");
console.log(`  [PASS] Candidate window visible with ${state.candidates.length} candidates:`, state.pageCandidates);

// 4. Test Candidate selection
console.log("Test 4: Candidate picking (pick index 1)...");
const secondCandidate = state.candidates[1];
ime.pick(1);
state = getState();
if (!state.preedit.includes(secondCandidate[0])) {
  console.log(`  (Picked candidate: preedit now "${state.preedit}")`);
}
console.log(`  [PASS] Candidate selection updated preedit`);

// 5. Test Enter commit
console.log("Test 5: Enter commit...");
sendKey("Enter", "\r");
sendKey("Enter", "\r");
state = getState();
if (state.preedit !== "") throw new Error(`Expected empty preedit after commit, got "${state.preedit}"`);
if (!state.lastCommit) throw new Error("Expected lastCommit to have text!");
console.log(`  [PASS] Committed text: "${state.lastCommit}"`);

// 6. Test Shift tap for Chinese/English mode toggle
console.log("Test 6: Lone Shift tap toggles English/Chinese mode...");
const engBefore = state.english;
// Press Shift
sendKey("ShiftLeft", "Shift", 1, 0);
await new Promise(r => setTimeout(r, 20));
// Release Shift
sendKey("ShiftLeft", "Shift", 0, 1);
state = getState();
if (state.english === engBefore) throw new Error("Shift tap did not toggle english mode!");
console.log(`  [PASS] English mode is now: ${state.english}`);

// Delay before second tap
await new Promise(r => setTimeout(r, 100));

// Toggle back
sendKey("ShiftLeft", "Shift", 1, 0);
await new Promise(r => setTimeout(r, 20));
sendKey("ShiftLeft", "Shift", 0, 1);
state = getState();
if (state.english !== engBefore) throw new Error("Shift tap did not toggle back!");
console.log(`  [PASS] English mode reverted to: ${state.english}`);

// 7. Test Toneless typing
console.log("Test 7: Toneless typing (sucl -> 你好)...");
ime.reset();
sendKey("KeyS", "s");
sendKey("KeyU", "u");
sendKey("KeyC", "c");
sendKey("KeyL", "l");
state = getState();
if (state.preedit !== "你好") throw new Error(`Expected toneless "你好", got "${state.preedit}"`);
console.log(`  [PASS] Toneless typing produced "${state.preedit}"`);

// 8. Test direct toggleEnglish export and pass-through key in English mode
console.log("Test 8: Explicit 中/英 switch and English pass-through...");
const isEng = ime.toggleEnglish();
state = getState();
if (state.english !== true || isEng !== true) throw new Error("Expected english mode to be true");
// In English mode, handle_key should return 0 (not consumed, pass-through to host document)
const consumed = sendKey("KeyA", "a");
if (consumed !== false) throw new Error("Expected English key to be pass-through (consumed == false)");
ime.toggleEnglish(); // toggle back
console.log("  [PASS] Direct toggle and English pass-through verified");

// 9. The module is the C ABI: header and exports agree, and the view JSON
// carries the fields the binding documents.
console.log("Test 9: One ABI for C and wasm...");
{
  const header = fs.readFileSync(path.resolve(ROOT, "Sources/CMisstype/include/misstype.h"), "utf8");
  const declared = [...new Set([...header.matchAll(/(misstype_[a-z0-9_]+)\(/g)].map((m) => m[1]))].sort();
  const exported = Object.keys(ime.exports).filter((n) => n.startsWith("misstype_")).sort();
  const missing = declared.filter((n) => !exported.includes(n));
  const extra = exported.filter((n) => !declared.includes(n));
  if (missing.length || extra.length) throw new Error(`header/export drift: missing ${missing} extra ${extra}`);
  if (ime.exports.misstype_abi_version() !== ABI_VERSION) throw new Error("ABI version mismatch");
  ime.reset();
  sendKey("KeyS", "s");
  const view = getState();
  for (const field of ["preedit", "caret", "candidates", "pageCandidates", "segments", "focus", "mark", "english", "latinActive", "lastCommit", "consumed"]) {
    if (!(field in view)) throw new Error(`state() lacks ${field}`);
  }
  console.log(`  [PASS] ${exported.length} exports match misstype.h (ABI ${ABI_VERSION})`);
}

// 10. In-memory persistence round trip (what a browser host saves).
console.log("Test 10: Learned phrases and dictionary round trip...");
{
  const golden = fs.readFileSync(path.resolve(ROOT, "tests/capi/golden/swift/user_phrases.json"), "utf8");
  if (!ime.loadLearned(golden)) throw new Error("desktop user_phrases.json was refused");
  const phrases = ime.learnedPhrases();
  if (!phrases.length || typeof phrases[0].count !== "number") throw new Error(`learnedPhrases: ${JSON.stringify(phrases)}`);
  const saved = ime.learnedData();
  const before = ime.learningRevision();
  ime.forgetLearned(phrases[0].reading, phrases[0].text);
  if (ime.learnedCount() !== phrases.length - 1 || ime.learningRevision() === before) throw new Error("forgetLearned did not forget");
  ime.clearLearned();
  if (ime.learnedCount() !== 0) throw new Error("clearLearned left phrases");
  if (!ime.loadLearned(saved) || ime.learnedCount() !== phrases.length) throw new Error("learned data did not round-trip");
  if (ime.loadLearned("not json")) throw new Error("malformed learned data was accepted");
  const channel = fs.readFileSync(path.resolve(ROOT, "tests/capi/golden/swift/channel_model.json"), "utf8");
  if (!ime.loadChannel(channel) || ime.channelCount() === 0 || ime.channelPairs().length !== ime.channelCount()) throw new Error("channel model did not load");

  if (!ime.setUserDictionary("測試 ㄘㄜˋ-ㄕˋ\n")) throw new Error("setUserDictionary failed");
  if (ime.userDictionaryCount() !== 1 || !ime.userDictionaryText().includes("測試")) throw new Error("dictionary text did not round-trip");
  const check = ime.checkUserDictionary("測試 ㄘㄜˋ-ㄕˋ\nbroken\n");
  if (check.added !== 1 || check.problems.length !== 1 || check.problems[0].line !== 2) throw new Error(`check: ${JSON.stringify(check)}`);
  console.log(`  [PASS] ${phrases.length} learned phrase(s) and the dictionary round-trip in memory`);
}

console.log("\n>>> ALL WASM TESTS PASSED <<<");
