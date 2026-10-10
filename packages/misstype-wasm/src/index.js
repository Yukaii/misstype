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

  // User dictionary: the desktop IMEs' `user_dictionary.tsv` (vChewing user
  // data, `text reading [weight]`; `!text reading` hides a built-in word). The
  // module keeps no files: persist `userDictionaryText()` when
  // `userDictionaryCount()` changes (a phrase filed with Shift+←/→ and Return).

  userDictionaryText() {
    return this._read(this.exports.misstype_wasm_user_dictionary_text());
  }

  userDictionaryCount() {
    return this.exports.misstype_wasm_user_dictionary_count();
  }

  /** Replaces the dictionary with `text`; unparseable lines are skipped. */
  setUserDictionary(text) {
    return this._withString(text, (ptr, len) => this.exports.misstype_wasm_set_user_dictionary(ptr, len)) === 1;
  }

  /** `{ added, hidden, problems: [{ line, message }] }` for editor text. */
  checkUserDictionary(text) {
    return JSON.parse(this._read(this._withString(text, (ptr, len) => this.exports.misstype_wasm_check_user_dictionary(ptr, len))));
  }

  /** Merges `source` into the editor `text`: `{ text, added, duplicates, skipped }`. Applies nothing. */
  importUserDictionary(source, text) {
    return JSON.parse(this._read(this._withString(source, (sp, sl) =>
      this._withString(text, (tp, tl) => this.exports.misstype_wasm_import_user_dictionary(sp, sl, tp, tl)))));
  }

  // Learning: what the decoder picks up from explicit candidate picks
  // (`user_lexicon.json`) and, with `channelLearning`, from typing slips
  // (`channel_model.json`). Same JSON as the desktop IMEs. The module keeps no
  // files: save `learnedData()` / `channelData()` when `learningRevision()`
  // changes and hand them back with `loadLearned` / `loadChannel` at start.
  // Settings: `userLearning` (default on), `channelLearning` (default off).

  learningRevision() {
    return this.exports.misstype_wasm_learning_revision();
  }

  learnedCount() {
    return this.exports.misstype_wasm_learned_count();
  }

  learnedData() {
    return this._read(this.exports.misstype_wasm_learned_data());
  }

  /** Replaces the learned phrases; false (nothing changed) if `data` is not a learned-phrases file. */
  loadLearned(data) {
    return this._withString(data, (ptr, len) => this.exports.misstype_wasm_load_learned(ptr, len)) === 1;
  }

  /** `[{ reading, text, count, updatedAt }]`, newest first. */
  learnedPhrases() {
    return JSON.parse(this._read(this.exports.misstype_wasm_learned_phrases()));
  }

  forgetLearned(reading, text) {
    this._withString(reading, (kp, kl) =>
      this._withString(text, (tp, tl) => this.exports.misstype_wasm_forget_learned(kp, kl, tp, tl)));
  }

  clearLearned() {
    this.exports.misstype_wasm_clear_learned();
  }

  channelCount() {
    return this.exports.misstype_wasm_channel_count();
  }

  channelData() {
    return this._read(this.exports.misstype_wasm_channel_data());
  }

  loadChannel(data) {
    return this._withString(data, (ptr, len) => this.exports.misstype_wasm_load_channel(ptr, len)) === 1;
  }

  /** `[{ typed, intended, cost }]`, most likely first; `exp(-cost)` is how often the slip happens. */
  channelPairs() {
    return JSON.parse(this._read(this.exports.misstype_wasm_channel_pairs()));
  }

  clearChannel() {
    this.exports.misstype_wasm_clear_channel();
  }

  takeCommitted() {
    const state = this.state();
    const text = state.lastCommit || "";
    this.exports.misstype_wasm_clear_committed();
    return text;
  }
}

export default MisstypeWasm;
