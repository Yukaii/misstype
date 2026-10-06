import { WASI } from "@bjorn3/browser_wasi_shim";

/**
 * Misstype WebAssembly Interactive Playground Controller
 */
export class MisstypePlayground {
  constructor(options = {}) {
    this.container = options.container;
    this.wasmUrl = options.wasmUrl || "misstype.wasm";
    this.lexiconUrl = options.lexiconUrl || "lexicon.tsv";
    this.tonelessUrl = options.tonelessUrl || "toneless.tsv";
    this.onStateChange = options.onStateChange || null;

    this.wasi = null;
    this.instance = null;
    this.exports = null;
    this.memory = null;

    this.ready = false;
    this.state = null;
    this.committedText = "";
    this.candidateOrientation = options.candidateOrientation || "vertical"; // 'vertical' | 'horizontal'

    this.setupDOM();
    this.bindEvents();
  }

  writeString(str) {
    if (!this.exports) return { ptr: 0, len: 0 };
    const enc = new TextEncoder();
    const bytes = enc.encode(str);
    const ptr = this.exports.misstype_wasm_alloc(bytes.length);
    new Uint8Array(this.memory.buffer, ptr, bytes.length).set(bytes);
    return { ptr, len: bytes.length };
  }

  readString(ptr) {
    if (!ptr || !this.memory) return "";
    const u8 = new Uint8Array(this.memory.buffer);
    let end = ptr;
    while (u8[end] !== 0) end++;
    return new TextDecoder().decode(u8.subarray(ptr, end));
  }

  getState() {
    if (!this.exports) return null;
    const ptr = this.exports.misstype_wasm_get_state_json();
    const jsonStr = this.readString(ptr);
    try {
      return JSON.parse(jsonStr);
    } catch (e) {
      console.error("Failed to parse state JSON:", jsonStr, e);
      return null;
    }
  }

  async init() {
    this.showLoading("正在下載隨打注音 Wasm 引擎及詞庫...");

    try {
      this.wasi = new WASI([], [], []);
      const wasiImport = { wasi_snapshot_preview1: this.wasi.wasiImport };

      // Fetch wasm module and lexicons in parallel
      const [wasmResponse, lexResponse, toneResponse] = await Promise.all([
        fetch(this.wasmUrl),
        fetch(this.lexiconUrl),
        fetch(this.tonelessUrl).catch(() => ({ ok: false }))
      ]);

      if (!wasmResponse.ok) throw new Error(`載入 wasm 失敗: HTTP ${wasmResponse.status}`);
      if (!lexResponse.ok) throw new Error(`載入詞庫失敗: HTTP ${lexResponse.status}`);

      this.showLoading("載入 Wasm 模組中...");
      const wasmBytes = await wasmResponse.arrayBuffer();
      const { instance } = await WebAssembly.instantiate(wasmBytes, wasiImport);
      this.instance = instance;
      this.exports = instance.exports;
      this.memory = instance.exports.memory;
      this.wasi.start(instance);

      this.showLoading("解析詞庫索引中（約 15 萬詞）...");
      const [lexText, toneText] = await Promise.all([
        lexResponse.text(),
        toneResponse.ok ? toneResponse.text() : Promise.resolve("")
      ]);

      const lexBuf = this.writeString(lexText);
      const toneBuf = this.writeString(toneText);

      const res = this.exports.misstype_wasm_init(
        lexBuf.ptr, lexBuf.len,
        toneBuf.ptr, toneBuf.len
      );

      this.exports.misstype_wasm_free(lexBuf.ptr);
      this.exports.misstype_wasm_free(toneBuf.ptr);

      if (res !== 1) {
        throw new Error("Wasm 初始化失敗");
      }

      this.ready = true;
      this.hideLoading();
      this.updateState();
      this.render();
      console.log("[MisstypePlayground] Wasm IME 就緒！");
    } catch (err) {
      console.error(err);
      this.showLoading(`初始化失敗: ${err.message}`);
    }
  }

  updateState() {
    this.state = this.getState();
    if (this.state && this.state.lastCommit) {
      this.committedText += this.state.lastCommit;
      this.exports.misstype_wasm_clear_committed();
    }
  }

  sendKey(code, keyText = "", modifiers = 0, phase = 0) {
    if (!this.ready) return false;
    const codeBuf = this.writeString(code);
    const textBuf = this.writeString(keyText);
    const consumed = this.exports.misstype_wasm_handle_key(
      codeBuf.ptr, codeBuf.len,
      textBuf.ptr, textBuf.len,
      modifiers, phase, Date.now() / 1000
    );
    this.exports.misstype_wasm_free(codeBuf.ptr);
    this.exports.misstype_wasm_free(textBuf.ptr);

    this.updateState();
    this.render();
    return consumed !== 0;
  }

  toggleEnglish() {
    if (!this.ready) return;
    if (this.exports.misstype_wasm_toggle_english) {
      this.exports.misstype_wasm_toggle_english();
    }
    this.updateState();
    this.render();
  }

  pickCandidate(index) {
    if (!this.ready) return;
    this.exports.misstype_wasm_pick_candidate(index);
    this.updateState();
    this.render();
    this.boxEl?.focus();
  }

  clear() {
    if (!this.ready) return;
    this.committedText = "";
    this.exports.misstype_wasm_reset();
    this.updateState();
    this.render();
    this.boxEl?.focus();
  }

  setupDOM() {
    if (!this.container) return;
    this.container.innerHTML = `
      <div class="playground-card">
        <div class="playground-header">
          <div class="playground-title">
            <span>線上試打 Playground</span>
            <span class="playground-badge loading" id="pg-badge">載入中</span>
          </div>
          <div class="playground-controls">
            <button class="mode-toggle-btn" id="pg-mode-btn" title="輕按 Shift 或點擊切換中英">中</button>
            <button class="clear-btn" id="pg-clear-btn">清空</button>
          </div>
        </div>

        <div class="playground-box" tabindex="0" id="pg-box" role="textbox" aria-label="隨打注音試打區">
          <span class="text-committed" id="pg-committed"></span><span class="text-preedit" id="pg-preedit"></span><span class="playground-caret" id="pg-caret"></span>
          <span class="playground-placeholder" id="pg-placeholder">點這裡開始試打...（例：輸入 su3cl3 打「你好」，或 sucl 免聲調打「你好」）</span>
        </div>

        <div class="playground-candidate-panel ${this.candidateOrientation}" id="pg-cand-panel" style="display: none;">
          <div class="candidate-header">
            <span class="cand-title">候選字</span>
            <div class="cand-pagination">
              <button class="cand-page-btn" id="pg-cand-prev" title="上一頁 (PageUp)">‹</button>
              <span id="pg-cand-page">1/1</span>
              <button class="cand-page-btn" id="pg-cand-next" title="下一頁 (PageDown)">›</button>
            </div>
          </div>
          <div class="candidate-list" id="pg-cand-list"></div>
        </div>

        <div class="playground-footer">
          <div class="tips-row">
            <span><kbd>↓</kbd> / <kbd>↑</kbd> 展開與瀏覽候選字</span>
            <span><kbd>A</kbd>~<kbd>K</kbd> / 點擊選字</span>
            <span><kbd>Shift</kbd> 輕按切換中/英</span>
            <span><kbd>Enter</kbd> 送字</span>
          </div>
          <div class="quick-examples">
            <span class="example-label">試試看點擊打字：</span>
            <button class="preset-chip" data-keys="sucl">你好 (免聲調)</button>
            <button class="preset-chip" data-keys="ru0tu8">今天 (免聲調)</button>
            <button class="preset-chip" data-keys="u;jp6">ㄧㄐㄢ (順序打反)</button>
            <button class="preset-chip" data-keys="h0ru0x;3">ㄘㄐㄧㄣˇ (按到隔壁)</button>
          </div>
        </div>

        <div class="playground-loading-mask" id="pg-loading">
          <div class="loading-spinner"></div>
          <div class="loading-text" id="pg-loading-text">正在載入 WebAssembly 核心...</div>
        </div>
      </div>
    `;

    this.boxEl = this.container.querySelector("#pg-box");
    this.committedEl = this.container.querySelector("#pg-committed");
    this.preeditEl = this.container.querySelector("#pg-preedit");
    this.caretEl = this.container.querySelector("#pg-caret");
    this.placeholderEl = this.container.querySelector("#pg-placeholder");
    this.candidatePanel = this.container.querySelector("#pg-cand-panel");
    this.candidateList = this.container.querySelector("#pg-cand-list");
    this.candidatePageEl = this.container.querySelector("#pg-cand-page");
    this.candPrevBtn = this.container.querySelector("#pg-cand-prev");
    this.candNextBtn = this.container.querySelector("#pg-cand-next");
    this.modeBtn = this.container.querySelector("#pg-mode-btn");
    this.loadingMask = this.container.querySelector("#pg-loading");
    this.loadingText = this.container.querySelector("#pg-loading-text");
    this.badgeEl = this.container.querySelector("#pg-badge");
    this.clearBtn = this.container.querySelector("#pg-clear-btn");
  }

  showLoading(text) {
    if (this.loadingText) this.loadingText.textContent = text;
    if (this.loadingMask) this.loadingMask.style.display = "flex";
  }

  hideLoading() {
    if (this.loadingMask) this.loadingMask.style.display = "none";
    if (this.badgeEl) {
      this.badgeEl.textContent = "已就緒";
      this.badgeEl.className = "playground-badge";
    }
  }

  bindEvents() {
    if (!this.boxEl) return;

    // Focus handler
    this.boxEl.addEventListener("click", () => {
      this.boxEl.focus();
    });

    let shiftDownTime = 0;
    let shiftInterrupted = false;

    // Keydown handler
    this.boxEl.addEventListener("keydown", (e) => {
      if (e.code === "ShiftLeft" || e.code === "ShiftRight") {
        shiftDownTime = performance.now();
        shiftInterrupted = false;
      } else {
        shiftInterrupted = true;
      }

      const modifiers = (e.shiftKey ? 1 : 0) |
                        (e.ctrlKey ? 2 : 0) |
                        (e.altKey ? 4 : 0) |
                        (e.metaKey ? 8 : 0) |
                        (e.getModifierState("CapsLock") ? 16 : 0);

      // Pass browser shortcut combos through (Cmd+C, Cmd+V, etc.)
      if ((e.metaKey || (e.ctrlKey && e.code !== "KeyJ" && e.code !== "KeyK")) &&
          e.code !== "KeyA" && e.code !== "KeyZ") {
        return;
      }

      const consumed = this.sendKey(e.code, e.key, modifiers, 0);
      if (consumed) {
        e.preventDefault();
      } else {
        // When unconsumed (e.g. in English mode or pass-through keys):
        // Simulate text typing into the committed buffer
        if (!e.ctrlKey && !e.metaKey && !e.altKey) {
          if (e.key.length === 1) {
            this.committedText += e.key;
            this.render();
            e.preventDefault();
          } else if (e.key === "Backspace") {
            if (this.committedText.length > 0) {
              this.committedText = this.committedText.slice(0, -1);
              this.render();
            }
            e.preventDefault();
          } else if (e.key === "Enter") {
            this.committedText += "\n";
            this.render();
            e.preventDefault();
          }
        }
      }
    });

    // Keyup handler (for Shift tap detection)
    this.boxEl.addEventListener("keyup", (e) => {
      const modifiers = (e.shiftKey ? 1 : 0) |
                        (e.ctrlKey ? 2 : 0) |
                        (e.altKey ? 4 : 0) |
                        (e.metaKey ? 8 : 0) |
                        (e.getModifierState("CapsLock") ? 16 : 0);

      if (e.code === "ShiftLeft" || e.code === "ShiftRight") {
        const consumed = this.sendKey(e.code, e.key, modifiers, 1);
        if (consumed) e.preventDefault();

        // If user tapped Shift quickly (< 450ms) with no intervening keys,
        // and WASM hasn't already toggled it:
        if (!shiftInterrupted && shiftDownTime > 0) {
          const tapDuration = performance.now() - shiftDownTime;
          if (tapDuration > 10 && tapDuration < 450) {
            if (!this.state?.modeChanged && !this.state?.latinToggled) {
              this.toggleEnglish();
            }
          }
        }
        shiftDownTime = 0;
        shiftInterrupted = false;
      }
    });

    // Mode toggle button click
    this.modeBtn?.addEventListener("click", (e) => {
      e.stopPropagation();
      this.toggleEnglish();
      this.boxEl.focus();
    });

    // Clear button
    this.clearBtn?.addEventListener("click", (e) => {
      e.stopPropagation();
      this.clear();
    });

    // Candidate prev/next buttons
    this.candPrevBtn?.addEventListener("click", (e) => {
      e.stopPropagation();
      this.sendKey("PageUp", "PageUp", 0, 0);
      this.boxEl.focus();
    });

    this.candNextBtn?.addEventListener("click", (e) => {
      e.stopPropagation();
      this.sendKey("PageDown", "PageDown", 0, 0);
      this.boxEl.focus();
    });

    // Preset chips
    this.container.querySelectorAll(".preset-chip").forEach((btn) => {
      btn.addEventListener("click", (e) => {
        e.stopPropagation();
        const keys = btn.dataset.keys;
        if (!keys) return;
        this.simulateTyping(keys);
      });
    });
  }

  async simulateTyping(keyString) {
    this.clear();
    this.boxEl.focus();

    for (const ch of keyString) {
      // Map char to KeyboardEvent code
      let code = "";
      if (ch >= 'a' && ch <= 'z') {
        code = `Key${ch.toUpperCase()}`;
      } else if (ch >= '0' && ch <= '9') {
        code = `Digit${ch}`;
      } else if (ch === ';') code = "Semicolon";
      else if (ch === '/') code = "Slash";
      else if (ch === '.') code = "Period";
      else if (ch === ',') code = "Comma";
      else if (ch === '-') code = "Minus";
      else code = "Key" + ch.toUpperCase();

      this.sendKey(code, ch, 0, 0);
      await new Promise(r => setTimeout(r, 90));
    }
  }

  render() {
    if (!this.state) return;

    // Committed text
    this.committedEl.textContent = this.committedText;

    // Preedit rendering with caret positioning
    const preedit = this.state.preedit || "";
    const caretPos = this.state.caret;

    if (this.committedText.length > 0 || preedit.length > 0) {
      this.placeholderEl.style.display = "none";
    } else {
      this.placeholderEl.style.display = "inline";
    }

    if (preedit.length > 0) {
      // Render segments
      const segments = this.state.segments || [];
      const focus = this.state.focus;

      if (segments.length > 0) {
        let segHtml = "";
        for (const [start, end] of segments) {
          const text = preedit.substring(start, end);
          const isFocused = focus && start === focus[0] && end === focus[1];
          segHtml += `<span class="text-segment ${isFocused ? "focused" : ""}">${escapeHtml(text)}</span>`;
        }
        this.preeditEl.innerHTML = segHtml;
      } else {
        this.preeditEl.textContent = preedit;
      }
    } else {
      this.preeditEl.innerHTML = "";
    }

    // Candidate window rendering
    if (this.state.showsCandidates && this.state.candidates.length > 0) {
      this.candidatePanel.style.display = "flex";
      this.candidatePageEl.textContent = `${this.state.page + 1}/${this.state.pageCount}`;

      const pageCandidates = this.state.pageCandidates || [];
      const selectionKeys = this.state.selectionKeys || [];
      const selectedIndex = this.state.pageSelected;

      let html = "";
      pageCandidates.forEach((cand, idx) => {
        const isSelected = idx === selectedIndex;
        const keyLabel = selectionKeys[idx] ? selectionKeys[idx].toUpperCase() : `${idx + 1}`;
        html += `
          <div class="candidate-item ${isSelected ? "selected" : ""}" data-index="${this.state.page * this.state.pageSize + idx}">
            <span class="cand-key">${keyLabel}</span>
            <span class="cand-text">${escapeHtml(cand)}</span>
          </div>
        `;
      });
      this.candidateList.innerHTML = html;

      // Bind candidate item clicks
      this.candidateList.querySelectorAll(".candidate-item").forEach((item) => {
        item.addEventListener("click", (e) => {
          e.stopPropagation();
          const idx = parseInt(item.dataset.index, 10);
          if (!isNaN(idx)) {
            this.pickCandidate(idx);
          }
        });
      });

      this.positionCandidatePanel();
    } else {
      this.candidatePanel.style.display = "none";
    }

    // Mode button label update
    if (this.modeBtn) {
      if (this.state.english) {
        this.modeBtn.textContent = "英";
        this.modeBtn.className = "mode-toggle-btn english";
      } else {
        this.modeBtn.textContent = "中";
        this.modeBtn.className = this.state.latinActive ? "mode-toggle-btn english" : "mode-toggle-btn";
      }
    }

    if (typeof this.onStateChange === "function") {
      this.onStateChange(this.state);
    }
  }

  positionCandidatePanel() {
    if (!this.caretEl || !this.candidatePanel) return;
    const caretRect = this.caretEl.getBoundingClientRect();
    const boxRect = this.boxEl.getBoundingClientRect();

    const left = caretRect.left - boxRect.left;
    const top = caretRect.bottom - boxRect.top + 8;

    this.candidatePanel.style.left = `${Math.max(0, left)}px`;
    this.candidatePanel.style.top = `${top}px`;
  }
}

function escapeHtml(str) {
  return str
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&#039;");
}
