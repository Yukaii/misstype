import { WASI } from "@bjorn3/browser_wasi_shim";

/**
 * Low-level browser binding for the Misstype WebAssembly module.
 *
 * The package does not bundle the lexicon or wasm binary. Pass URLs to
 * `MisstypeWasm.load`, so applications can cache/version those assets with
 * their own deployment.
 */
export class MisstypeWasm {
  constructor(instance, wasi) {
    this.instance = instance;
    this.wasi = wasi;
    this.exports = instance.exports;
    this.memory = this.exports.memory;
  }

  static async load({ wasmUrl, lexiconUrl, tonelessUrl = null, englishUrl = null } = {}) {
    if (!wasmUrl || !lexiconUrl) throw new TypeError("wasmUrl and lexiconUrl are required");
    const wasi = new WASI([], [], []);
    const [wasmResponse, lexResponse, toneResponse] = await Promise.all([
      fetch(wasmUrl),
      fetch(lexiconUrl),
      tonelessUrl ? fetch(tonelessUrl) : Promise.resolve({ ok: false }),
    ]);
    if (!wasmResponse.ok) throw new Error(`Failed to load Misstype wasm: HTTP ${wasmResponse.status}`);
    if (!lexResponse.ok) throw new Error(`Failed to load Misstype lexicon: HTTP ${lexResponse.status}`);
    const { instance } = await WebAssembly.instantiate(await wasmResponse.arrayBuffer(), {
      wasi_snapshot_preview1: wasi.wasiImport,
    });
    wasi.start(instance);
    const api = new MisstypeWasm(instance, wasi);
    api.init(await lexResponse.text(), toneResponse.ok ? await toneResponse.text() : "");
    if (englishUrl && api.exports.misstype_wasm_load_english) {
      const englishResponse = await fetch(englishUrl);
      if (englishResponse.ok) api.loadEnglish(await englishResponse.text());
    }
    return api;
  }

  _write(text) {
    const bytes = new TextEncoder().encode(text);
    const ptr = this.exports.misstype_wasm_alloc(bytes.length);
    if (!ptr) throw new Error("Misstype wasm allocation failed");
    new Uint8Array(this.memory.buffer, ptr, bytes.length).set(bytes);
    return { ptr, len: bytes.length };
  }

  _read(ptr) {
    if (!ptr) return "";
    const bytes = new Uint8Array(this.memory.buffer);
    let end = ptr;
    while (bytes[end] !== 0) end += 1;
    return new TextDecoder().decode(bytes.subarray(ptr, end));
  }

  _withString(text, fn) {
    const value = this._write(text);
    try {
      return fn(value.ptr, value.len);
    } finally {
      this.exports.misstype_wasm_free(value.ptr);
    }
  }

  init(lexicon, toneless = "") {
    const result = this._withString(lexicon, (lexPtr, lexLen) =>
      this._withString(toneless, (tonePtr, toneLen) =>
        this.exports.misstype_wasm_init(lexPtr, lexLen, tonePtr, toneLen)));
    if (result !== 1) throw new Error("Misstype wasm initialization failed");
    return this;
  }

  loadEnglish(tsv) {
    return this._withString(tsv, (ptr, len) => this.exports.misstype_wasm_load_english(ptr, len)) === 1;
  }

  state() {
    return JSON.parse(this._read(this.exports.misstype_wasm_get_state_json()));
  }

  key(code, text = "", modifiers = 0, phase = 0, timestamp = performance.now() / 1000) {
    const result = this._withString(code, (codePtr, codeLen) =>
      this._withString(text, (textPtr, textLen) => this.exports.misstype_wasm_handle_key(
        codePtr, codeLen, textPtr, textLen, modifiers, phase, timestamp)));
    return result !== 0;
  }

  pick(index) {
    this.exports.misstype_wasm_pick_candidate(index);
  }

  commit() {
    return this.exports.misstype_wasm_commit() !== 0;
  }

  reset() {
    this.exports.misstype_wasm_reset();
  }

  toggleEnglish() {
    return this.exports.misstype_wasm_toggle_english() !== 0;
  }

  setEnglish(enabled) {
    return this.exports.misstype_wasm_set_english(enabled ? 1 : 0) !== 0;
  }

  setSetting(name, value) {
    return this._withString(name, (ptr, len) => this.exports.misstype_wasm_set_setting(ptr, len, Number(value)));
  }

  takeCommitted() {
    const state = this.state();
    const text = state.lastCommit || "";
    this.exports.misstype_wasm_clear_committed();
    return text;
  }
}

export default MisstypeWasm;
