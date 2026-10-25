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
    this.wordModelLoaded = false;
  }

  static async load({ wasmUrl, lexiconUrl, tonelessUrl = null, englishUrl = null, homophoneUrl = null, wordModelUrl = null, wordModelWeight = 0.5 } = {}) {
    if (!wasmUrl || !lexiconUrl) throw new TypeError("wasmUrl and lexiconUrl are required");
    const [wasmResponse, lexResponse, toneResponse] = await Promise.all([
      fetch(wasmUrl),
      fetch(lexiconUrl),
      tonelessUrl ? fetch(tonelessUrl) : Promise.resolve({ ok: false }),
    ]);
    if (!wasmResponse.ok) throw new Error(`Failed to load Misstype wasm: HTTP ${wasmResponse.status}`);
    if (!lexResponse.ok) throw new Error(`Failed to load Misstype lexicon: HTTP ${lexResponse.status}`);
    const api = await MisstypeWasm.fromBytes({
      wasm: await wasmResponse.arrayBuffer(),
      lexicon: await lexResponse.text(),
      toneless: toneResponse.ok ? await toneResponse.text() : "",
    });
    if (englishUrl && api.exports.misstype_wasm_load_english) {
      const englishResponse = await fetch(englishUrl);
      if (englishResponse.ok) api.loadEnglish(await englishResponse.text());
    }
    // Experimental sparse model is opt-in. It replaces the homophone table;
    // don't fetch both when the model succeeds. Missing/old wasm falls back.
    if (wordModelUrl && wordModelWeight > 0 && api.exports.misstype_wasm_load_word_model) {
      try {
        const response = await fetch(wordModelUrl);
        if (response.ok) api.loadWordModel(new Uint8Array(await response.arrayBuffer()), wordModelWeight);
      } catch { /* optional */ }
    }
    // Optional homophone word-bigram table; a missing or malformed file, or an
    // older wasm without the export, leaves decoding unchanged.
    if (!api.wordModelLoaded && homophoneUrl && api.exports.misstype_wasm_load_homophone) {
      try {
        const homophoneResponse = await fetch(homophoneUrl);
        if (homophoneResponse.ok) api.loadHomophone(new Uint8Array(await homophoneResponse.arrayBuffer()));
      } catch { /* optional */ }
    }
    return api;
  }

  /**
   * Same as `load`, from assets already in memory (an app that bundles them,
   * such as the Obsidian plugin). `wasm` and `homophone` are bytes, the
   * lexicons text; everything but `wasm` and `lexicon` is optional.
   */
  static async fromBytes({ wasm, lexicon, toneless = "", english = "", homophone = null } = {}) {
    if (!wasm || !lexicon) throw new TypeError("wasm and lexicon are required");
    const wasi = new WASI([], [], []);
    const { instance } = await WebAssembly.instantiate(wasm, { wasi_snapshot_preview1: wasi.wasiImport });
    wasi.start(instance);
    const api = new MisstypeWasm(instance, wasi);
    api.init(lexicon, toneless);
    if (english && api.exports.misstype_wasm_load_english) api.loadEnglish(english);
    if (homophone && api.exports.misstype_wasm_load_homophone) api.loadHomophone(new Uint8Array(homophone));
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
    this.wordModelLoaded = false;
    return this;
  }

  /** @param {Uint8Array} bytes contents of `homophone.bin` */
  loadHomophone(bytes) {
    const ptr = this.exports.misstype_wasm_alloc(bytes.length);
    if (!ptr) return false;
    try {
      new Uint8Array(this.memory.buffer, ptr, bytes.length).set(bytes);
      return this.exports.misstype_wasm_load_homophone(ptr, bytes.length) === 1;
    } finally {
      this.exports.misstype_wasm_free(ptr);
    }
  }

  loadWordModel(bytes, weight = 0.5) {
    if (!this.exports.misstype_wasm_load_word_model || bytes.length > 8 * 1024 * 1024 ||
        !Number.isFinite(weight) || weight < 0 || weight > 1) return false;
    const ptr = this.exports.misstype_wasm_alloc(bytes.length);
    if (!ptr) return false;
    try {
      new Uint8Array(this.memory.buffer, ptr, bytes.length).set(bytes);
      const loaded = this.exports.misstype_wasm_load_word_model(ptr, bytes.length, weight) === 1;
      if (loaded) this.wordModelLoaded = true;
      return loaded;
    } finally {
      this.exports.misstype_wasm_free(ptr);
    }
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
