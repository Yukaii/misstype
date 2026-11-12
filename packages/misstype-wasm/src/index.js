import { WASI } from "@bjorn3/browser_wasi_shim";

/**
 * Browser binding for the Misstype WebAssembly module.
 *
 * The module exports the same C ABI as the desktop IMEs
 * (`misstype.h`, ABI v3): an engine made from in-memory lexicons and one
 * session over it. This class owns both and keeps the host-side state the
 * desktop adapters keep themselves (the last key result, text committed
 * since `takeCommitted`). `this.exports` is the raw ABI.
 *
 * The package does not bundle the lexicon or wasm binary. Pass URLs to
 * `MisstypeWasm.load`, so applications can cache/version those assets with
 * their own deployment.
 */

// misstype.h struct layouts on wasm32 (asserted in core-zig/src/capi.zig).
const EVENT_SIZE = 32;
const RESULT_SIZE = 20;
const KIND_CHARACTER = 0;
const NO_RESULT = { consumed: false, beep: false, modeChanged: false, latinToggled: false };

export const ABI_VERSION = 3;

export class MisstypeWasm {
  constructor(instance, wasi) {
    this.instance = instance;
    this.wasi = wasi;
    this.exports = instance.exports;
    this.memory = this.exports.memory;
    if (this.exports.misstype_abi_version() !== ABI_VERSION) {
      throw new Error(`Misstype wasm ABI ${this.exports.misstype_abi_version()}, binding expects ${ABI_VERSION}`);
    }
    this.engine = 0;
    this.session = 0;
    this.wordModelLoaded = false;
    this.last = NO_RESULT;
    this.committed = null;
    // Reused scratch: one key event, one key result, a label out-pointer and
    // three int32 out-parameters.
    this.scratch = this.exports.misstype_alloc(EVENT_SIZE + RESULT_SIZE + 16);
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
    if (englishUrl) {
      const englishResponse = await fetch(englishUrl);
      if (englishResponse.ok) api.loadEnglish(await englishResponse.text());
    }
    // Experimental sparse model is opt-in. It replaces the homophone table;
    // don't fetch both when the model succeeds.
    if (wordModelUrl && wordModelWeight > 0) {
      try {
        const response = await fetch(wordModelUrl);
        if (response.ok) api.loadWordModel(new Uint8Array(await response.arrayBuffer()), wordModelWeight);
      } catch { /* optional */ }
    }
    // Optional homophone word-bigram table; a missing or malformed file
    // leaves decoding unchanged.
    if (!api.wordModelLoaded && homophoneUrl) {
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
    if (english) api.loadEnglish(english);
    if (homophone) api.loadHomophone(new Uint8Array(homophone));
    return api;
  }

  // ---- memory helpers ----

  _bytes(data) {
    return typeof data === "string" ? new TextEncoder().encode(data) : data;
  }

  /** Copies `data` (string or bytes) into module memory, NUL-terminated. */
  _write(data) {
    const bytes = this._bytes(data);
    const ptr = this.exports.misstype_alloc(bytes.length + 1);
    if (!ptr) throw new Error("Misstype wasm allocation failed");
    const view = new Uint8Array(this.memory.buffer, ptr, bytes.length + 1);
    view.set(bytes);
    view[bytes.length] = 0;
    return { ptr, len: bytes.length };
  }

  /** Runs `fn(ptr, len)` over a temporary copy of each argument. */
  _with(values, fn) {
    const written = values.map((v) => (v == null ? { ptr: 0, len: 0 } : this._write(v)));
    try {
      return fn(...written.flatMap((w) => [w.ptr, w.len]));
    } finally {
      for (const w of written) if (w.ptr) this.exports.misstype_free(w.ptr);
    }
  }

  _readZ(ptr) {
    if (!ptr) return "";
    const bytes = new Uint8Array(this.memory.buffer);
    let end = ptr;
    while (bytes[end] !== 0) end += 1;
    return new TextDecoder().decode(bytes.subarray(ptr, end));
  }

  /** Reads and frees a string the ABI returned (caller-owned). */
  _take(ptr) {
    const text = this._readZ(ptr);
    if (ptr) this.exports.misstype_string_free(ptr);
    return text;
  }

  _i32(offset) {
    return new DataView(this.memory.buffer).getInt32(offset, true);
  }

  _appendCommit(text) {
    if (text) this.committed = (this.committed ?? "") + text;
  }

  // ---- lifecycle and resources ----

  init(lexicon, toneless = "") {
    this._free();
    this.engine = this._with([lexicon, toneless], (lp, ll, tp, tl) =>
      this.exports.misstype_engine_new_from_data(lp, ll, tp, toneless ? tl : 0));
    if (!this.engine) throw new Error("Misstype wasm initialization failed");
    // Browser defaults (as the pre-v3 module set them): the panel opens on
    // Tab/arrows, Return confirms a pick before it sends, and a Shift tap may
    // be a little slower than on a hardware IME.
    this.setSetting("autoShowCandidates", false);
    this.setSetting("returnConfirmsSelection", true);
    this.setSetting("shiftToggle", true);
    this.setSetting("shiftTapLimitMs", 350);
    this.session = this.exports.misstype_session_new(this.engine);
    if (!this.session) throw new Error("Misstype wasm session failed");
    this.wordModelLoaded = false;
    this.last = NO_RESULT;
    this.committed = null;
    return this;
  }

  _free() {
    if (this.session) this.exports.misstype_session_free(this.session);
    if (this.engine) this.exports.misstype_engine_free(this.engine);
    this.session = 0;
    this.engine = 0;
  }

  /** Releases the engine and session; the instance is unusable afterwards. */
  dispose() {
    this._free();
    if (this.scratch) this.exports.misstype_free(this.scratch);
    this.scratch = 0;
  }

  /** @param {Uint8Array} bytes contents of `homophone.bin` */
  loadHomophone(bytes) {
    return this._with([bytes], (p, l) => this.exports.misstype_engine_load_homophone(this.engine, p, l)) === 1;
  }

  loadWordModel(bytes, weight = 0.5) {
    const loaded = this._with([bytes], (p, l) => this.exports.misstype_engine_load_word_model(this.engine, p, l, weight)) === 1;
    if (loaded) this.wordModelLoaded = true;
    return loaded;
  }

  loadEnglish(tsv) {
    return this._with([tsv], (p, l) => this.exports.misstype_engine_load_english(this.engine, p, l)) === 1;
  }

  // ---- typing ----

  /**
   * Feeds one DOM key event. `code` is `KeyboardEvent.code`, `text` the
   * character it types, `modifiers` the misstype.h MOD_* bits after the
   * event, `phase` 1 for key-up. Returns whether the engine consumed it.
   */
  key(code, text = "", modifiers = 0, phase = 0, timestamp = performance.now() / 1000) {
    const ex = this.exports;
    const event = this.scratch;
    const result = event + EVENT_SIZE;
    const labelOut = result + RESULT_SIZE;
    return this._with([code, text || null], (codePtr, _cl, textPtr) => {
      const kind = ex.misstype_key_from_dom_code(codePtr, textPtr, labelOut);
      const view = new DataView(this.memory.buffer);
      view.setInt32(event, kind, true);
      view.setUint32(event + 4, kind === KIND_CHARACTER ? view.getUint32(labelOut, true) : 0, true);
      view.setUint32(event + 8, textPtr, true);
      view.setUint32(event + 12, modifiers & 0x1f, true);
      view.setInt32(event + 16, phase === 1 ? 1 : 0, true);
      view.setInt32(event + 20, -1, true);
      view.setFloat64(event + 24, timestamp > 0 ? timestamp : -1, true);
      ex.misstype_session_handle_into(this.session, event, result);
      this.last = {
        consumed: this._i32(result) !== 0,
        beep: this._i32(result + 8) !== 0,
        modeChanged: this._i32(result + 12) !== 0,
        latinToggled: this._i32(result + 16) !== 0,
      };
      this._appendCommit(this._take(new DataView(this.memory.buffer).getUint32(result + 4, true)));
      return this.last.consumed;
    });
  }

  /**
   * The view (UTF-16 offsets) plus the host state: `lastCommit` (text
   * committed since `takeCommitted`, or null) and the last key's
   * `consumed`, `beep`, `modeChanged`, `latinToggled`.
   */
  state() {
    const view = JSON.parse(this._take(this.exports.misstype_session_view_json(this.session)) || "{}");
    return { ...view, lastCommit: this.committed, ...this.last };
  }

  pick(index) {
    this.exports.misstype_session_pick(this.session, index);
  }

  commit() {
    const text = this._take(this.exports.misstype_session_commit(this.session));
    this._appendCommit(text);
    return text !== "";
  }

  /** A fresh session over the same engine (learning is kept). */
  reset() {
    if (this.session) this.exports.misstype_session_free(this.session);
    this.session = this.exports.misstype_session_new(this.engine);
    this.committed = null;
    this.last = NO_RESULT;
  }

  isEnglish() {
    return this.exports.misstype_engine_is_english(this.engine) !== 0;
  }

  toggleEnglish() {
    return this.setEnglish(!this.isEnglish());
  }

  /** Switches 中/英, committing any composition first; returns the new mode. */
  setEnglish(enabled) {
    this._appendCommit(this._take(this.exports.misstype_session_set_english(this.session, enabled ? 1 : 0)));
    return this.isEnglish();
  }

  /** misstype.h `misstype_engine_set_setting`; booleans as true/false. */
  setSetting(name, value) {
    return this._with([name], (p) => this.exports.misstype_engine_set_setting(this.engine, p, Number(value))) === 1;
  }

  takeCommitted() {
    const text = this.committed || "";
    this.committed = null;
    return text;
  }

  // ---- user dictionary ----
  // The desktop IMEs' `user_dictionary.tsv` (vChewing user data,
  // `text reading [weight]`; `!text reading` hides a built-in word). The
  // module keeps no files: persist `userDictionaryText()` when
  // `userDictionaryCount()` changes (a phrase filed with Shift+←/→ and Return).

  userDictionaryText() {
    return this._take(this.exports.misstype_engine_user_dictionary_text(this.engine));
  }

  userDictionaryCount() {
    return this.exports.misstype_engine_user_dictionary_count(this.engine);
  }

  /** Replaces the dictionary with `text`; unparseable lines are skipped. */
  setUserDictionary(text) {
    return this._with([text], (p, l) => this.exports.misstype_engine_set_user_dictionary_text(this.engine, p, l)) === 1;
  }

  /** `{ added, hidden, problems: [{ line, message }] }` for editor text. */
  checkUserDictionary(text) {
    const out = this.scratch + EVENT_SIZE + RESULT_SIZE + 4;
    const rows = this._with([text], (p) => this._take(this.exports.misstype_user_dictionary_check(p, out, out + 4)));
    return {
      added: this._i32(out),
      hidden: this._i32(out + 4),
      problems: rows.split("\n").filter(Boolean).map((row) => {
        const tab = row.indexOf("\t");
        return { line: Number(row.slice(0, tab)), message: row.slice(tab + 1) };
      }),
    };
  }

  /** Merges `source` into the editor `text`: `{ text, added, duplicates, skipped }`. Applies nothing. */
  importUserDictionary(source, text) {
    const out = this.scratch + EVENT_SIZE + RESULT_SIZE + 4;
    const merged = this._with([text, source], (tp, _tl, sp) =>
      this._take(this.exports.misstype_user_dictionary_import(tp, sp, out, out + 4, out + 8)));
    return { text: merged, added: this._i32(out), duplicates: this._i32(out + 4), skipped: this._i32(out + 8) };
  }

  // ---- learning ----
  // What the decoder picks up from explicit candidate picks
  // (`user_lexicon.json`) and, with `channelLearning`, from typing slips
  // (`channel_model.json`). Same JSON as the desktop IMEs. The module keeps no
  // files: save `learnedData()` / `channelData()` when `learningRevision()`
  // changes and hand them back with `loadLearned` / `loadChannel` at start.
  // Settings: `userLearning` (default on), `channelLearning` (default off).

  learningRevision() {
    return this.exports.misstype_engine_learning_revision(this.engine);
  }

  learnedCount() {
    return this.exports.misstype_engine_learned_phrase_count(this.engine);
  }

  learnedData() {
    return this._take(this.exports.misstype_engine_learned_data(this.engine));
  }

  /** Replaces the learned phrases; false (nothing changed) if `data` is not a learned-phrases file. */
  loadLearned(data) {
    return this._with([data], (p, l) => this.exports.misstype_engine_load_learned_data(this.engine, p, l)) === 1;
  }

  /** `[{ reading, text, count, updatedAt }]`, newest first. */
  learnedPhrases() {
    return this._take(this.exports.misstype_engine_learned_phrases(this.engine))
      .split("\n").filter(Boolean).map((row) => {
        const [reading, text, count, updatedAt] = row.split("\t");
        return { reading, text, count: Number(count), updatedAt: Number(updatedAt) };
      });
  }

  forgetLearned(reading, text) {
    this._with([reading, text], (rp, _rl, tp) => this.exports.misstype_engine_forget_learned_phrase(this.engine, rp, tp));
  }

  clearLearned() {
    this.exports.misstype_engine_clear_learned_phrases(this.engine);
  }

  channelCount() {
    return this.exports.misstype_engine_channel_pair_count(this.engine);
  }

  channelData() {
    return this._take(this.exports.misstype_engine_channel_data(this.engine));
  }

  loadChannel(data) {
    return this._with([data], (p, l) => this.exports.misstype_engine_load_channel_data(this.engine, p, l)) === 1;
  }

  /** `[{ typed, intended, cost }]`, most likely first; `exp(-cost)` is how often the slip happens. */
  channelPairs() {
    return this._take(this.exports.misstype_engine_channel_pairs(this.engine))
      .split("\n").filter(Boolean).map((row) => {
        const [typed, intended, cost] = row.split("\t");
        return { typed, intended, cost: Number(cost) };
      });
  }

  clearChannel() {
    this.exports.misstype_engine_clear_channel(this.engine);
  }
}

export default MisstypeWasm;
