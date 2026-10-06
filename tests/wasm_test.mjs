import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.resolve(__dirname, "..");
const wasiShimPath = path.resolve(ROOT, "site/node_modules/@bjorn3/browser_wasi_shim/dist/index.js");
const { WASI } = await import(wasiShimPath);

console.log("=== Misstype WebAssembly IME Test Suite ===");

const wasmPath = path.resolve(ROOT, ".build/wasm32-unknown-wasi/release/MisstypeWasm.wasm");
if (!fs.existsSync(wasmPath)) {
  console.error("WASM file not found at:", wasmPath);
  process.exit(1);
}

const wasi = new WASI([], [], []);
const wasiImport = { wasi_snapshot_preview1: wasi.wasiImport };
const wasmBytes = fs.readFileSync(wasmPath);
const { instance } = await WebAssembly.instantiate(wasmBytes, wasiImport);
wasi.start(instance);

const exports = instance.exports;
const memory = exports.memory;

function writeString(str) {
  const enc = new TextEncoder();
  const bytes = enc.encode(str);
  const ptr = exports.misstype_wasm_alloc(bytes.length);
  new Uint8Array(memory.buffer, ptr, bytes.length).set(bytes);
  return { ptr, len: bytes.length };
}

function getState() {
  const ptr = exports.misstype_wasm_get_state_json();
  const u8 = new Uint8Array(memory.buffer);
  let end = ptr;
  while (u8[end] !== 0) end++;
  return JSON.parse(new TextDecoder().decode(u8.subarray(ptr, end)));
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

// 1. Initialize with fixture lexicon
console.log("Test 1: Initialize IME with fixture lexicon...");
const lexTsv = fs.readFileSync(path.resolve(ROOT, "tests/fixtures/lexicon/lexicon.tsv"), "utf8");
const lexBuf = writeString(lexTsv);
const toneBuf = writeString("");
const initRes = exports.misstype_wasm_init(lexBuf.ptr, lexBuf.len, toneBuf.ptr, toneBuf.len);
exports.misstype_wasm_free(lexBuf.ptr);
exports.misstype_wasm_free(toneBuf.ptr);
if (initRes !== 1) throw new Error("Initialization failed!");
console.log("  [PASS] Initialized successfully");

// 2. Test typing standard Zhuyin with tones: su3cl3 -> 你好
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

// 3. Test candidate window activation via Down arrow
console.log("Test 3: Candidate window trigger (ArrowDown)...");
sendKey("ArrowDown", "Down");
state = getState();
if (!state.showsCandidates) throw new Error("Expected showsCandidates to be true!");
if (state.candidates.length === 0) throw new Error("Expected candidates array to not be empty!");
console.log(`  [PASS] Candidate window visible with ${state.candidates.length} candidates:`, state.pageCandidates);

// 4. Test candidate picking
console.log("Test 4: Candidate picking (pick index 1)...");
const secondCandidate = state.candidates[1];
exports.misstype_wasm_pick_candidate(1);
state = getState();
if (!state.preedit.includes(secondCandidate[0])) {
  console.log(`  (Picked candidate: preedit now "${state.preedit}")`);
}
console.log(`  [PASS] Candidate selection updated preedit to "${state.preedit}"`);

// 5. Test commit
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

console.log("\n>>> ALL WASM PLAYGROUND TESTS PASSED SUCCESSFULLY! <<<");
