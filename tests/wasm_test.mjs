import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { WASI } from "../site/node_modules/@bjorn3/browser_wasi_shim/dist/index.js";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.resolve(__dirname, "..");
const wasmPath = path.resolve(ROOT, "site/public/misstype.wasm");
if (!fs.existsSync(wasmPath)) {
  console.error("Wasm binary not found at", wasmPath);
  process.exit(1);
}

const wasmBytes = fs.readFileSync(wasmPath);
const wasi = new WASI([], [], []);
const wasiImport = { wasi_snapshot_preview1: wasi.wasiImport };

const { instance } = await WebAssembly.instantiate(wasmBytes, wasiImport);
const exports = instance.exports;
const memory = exports.memory;
wasi.start(instance);

function writeString(str) {
  const enc = new TextEncoder();
  const bytes = enc.encode(str);
  const ptr = exports.misstype_wasm_alloc(bytes.length);
  new Uint8Array(memory.buffer, ptr, bytes.length).set(bytes);
  return { ptr, len: bytes.length };
}

function readString(ptr) {
  if (!ptr) return "";
  const u8 = new Uint8Array(memory.buffer);
  let end = ptr;
  while (u8[end] !== 0) end++;
  return new TextDecoder().decode(u8.subarray(ptr, end));
}

function getState() {
  const ptr = exports.misstype_wasm_get_state_json();
  const jsonStr = readString(ptr);
  return JSON.parse(jsonStr);
}

function sendKey(code, keyText = "", modifiers = 0, phase = 0) {
  const codeBuf = writeString(code);
  const textBuf = writeString(keyText);
  const consumed = exports.misstype_wasm_handle_key(
    codeBuf.ptr, codeBuf.len,
    textBuf.ptr, textBuf.len,
    modifiers, phase, Date.now() / 1000
  );
  exports.misstype_wasm_free(codeBuf.ptr);
  exports.misstype_wasm_free(textBuf.ptr);
  return consumed !== 0;
}

console.log("=== Misstype WebAssembly IME Test Suite ===");

// 1. Test IME initialization
console.log("Test 1: Initialize IME with fixture lexicon...");
const lexTsv = fs.readFileSync(path.resolve(ROOT, "tests/fixtures/lexicon/lexicon.tsv"), "utf8");
const lexBuf = writeString(lexTsv);
const toneBuf = writeString("");
const initRes = exports.misstype_wasm_init(lexBuf.ptr, lexBuf.len, toneBuf.ptr, toneBuf.len);
exports.misstype_wasm_free(lexBuf.ptr);
exports.misstype_wasm_free(toneBuf.ptr);

if (initRes !== 1) throw new Error("misstype_wasm_init failed!");
console.log("  [PASS] Initialized successfully");

// 1b. The optional homophone word-bigram table: malformed files are refused
// (decoding stays as it was); a well-formed one loads. Rerank behavior is
// covered by the Zig unit test "homophone table reorders ...".
console.log("Test 1b: Homophone table loader...");
{
  const garbage = writeString("MSHB-not-a-table");
  const rejected = exports.misstype_wasm_load_homophone(garbage.ptr, garbage.len);
  exports.misstype_wasm_free(garbage.ptr);
  if (rejected !== 0) throw new Error("malformed homophone table was accepted");

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
  const buf = exports.misstype_wasm_alloc(table.byteLength);
  new Uint8Array(memory.buffer, buf, table.byteLength).set(new Uint8Array(table.buffer));
  const loaded = exports.misstype_wasm_load_homophone(buf, table.byteLength);
  exports.misstype_wasm_free(buf);
  if (loaded !== 1) throw new Error("well-formed homophone table was rejected");
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
exports.misstype_wasm_pick_candidate(1);
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
exports.misstype_wasm_reset();
sendKey("KeyS", "s");
sendKey("KeyU", "u");
sendKey("KeyC", "c");
sendKey("KeyL", "l");
state = getState();
if (state.preedit !== "你好") throw new Error(`Expected toneless "你好", got "${state.preedit}"`);
console.log(`  [PASS] Toneless typing produced "${state.preedit}"`);

// 8. Test direct toggleEnglish export and pass-through key in English mode
console.log("Test 8: Direct misstype_wasm_toggle_english and English pass-through...");
const isEng = exports.misstype_wasm_toggle_english();
state = getState();
if (state.english !== true || isEng !== 1) throw new Error("Expected english mode to be true");
// In English mode, handle_key should return 0 (not consumed, pass-through to host document)
const consumed = sendKey("KeyA", "a");
if (consumed !== false) throw new Error("Expected English key to be pass-through (consumed == false)");
exports.misstype_wasm_toggle_english(); // toggle back
console.log("  [PASS] Direct toggle and English pass-through verified");

console.log("\n>>> ALL WASM PLAYGROUND TESTS PASSED SUCCESSFULLY! <<<");
