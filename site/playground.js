import { WASI } from "@bjorn3/browser_wasi_shim";
import "./playground.css";

/**
 * Misstype WebAssembly Interactive Playground Controller
 */
export class MisstypePlayground {
  constructor(options = {}) {
    this.container = options.container;
    this.wasmUrl = options.wasmUrl || "misstype.wasm";
    this.lexiconUrl = options.lexiconUrl || "lexicon.tsv";
    this.tonelessUrl = options.tonelessUrl || "toneless.tsv";
    this.englishUrl = options.englishUrl || "english.tsv";
    this.onStateChange = options.onStateChange || null;
    this.onReady = options.onReady;
    this.onError = options.onError;

    this.wasi = null;
    this.instance = null;
    this.exports = null;
    this.memory = null;

    this.ready = false;
    this.state = null;
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
    this.showLoading("載入中，請稍候⋯");

    try {
      this.wasi = new WASI([], [], []);
      const wasiImport = { wasi_snapshot_preview1: this.wasi.wasiImport };

      // Fetch wasm module and lexicons in parallel
      const [wasmResponse, lexResponse, toneResponse] = await Promise.all([
        fetch(this.wasmUrl),
        fetch(this.lexiconUrl),
        fetch(this.tonelessUrl).catch(() => ({ ok: false }))
      ]);

      if (!wasmResponse.ok) throw new Error(`載入失敗: HTTP ${wasmResponse.status}`);
      if (!lexResponse.ok) throw new Error(`載入詞庫失敗: HTTP ${lexResponse.status}`);

      const wasmBytes = await wasmResponse.arrayBuffer();
      const { instance } = await WebAssembly.instantiate(wasmBytes, wasiImport);
      this.instance = instance;
      this.exports = instance.exports;
      this.memory = instance.exports.memory;
      this.wasi.start(instance);

      this.showLoading("整理詞庫中⋯");
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
        throw new Error("初始化失敗");
      }

      // Optional: word list for mixed Chinese/English typing. An older wasm
      // without the export, or a missing file, just leaves that pass off.
      if (this.exports.misstype_wasm_load_english) {
        try {
          const englishResponse = await fetch(this.englishUrl);
          if (englishResponse.ok) {
            const englishBuf = this.writeString(await englishResponse.text());
            this.exports.misstype_wasm_load_english(englishBuf.ptr, englishBuf.len);
            this.exports.misstype_wasm_free(englishBuf.ptr);
          }
        } catch (err) {
          console.warn("english word list unavailable", err);
        }
      }

      this.ready = true;
      this.hideLoading();
      this.updateState();
      this.render();
      this.onReady?.();
    } catch (err) {
      console.error(err);
      this.onError?.(err);
    }
  }

  updateState() {
    this.state = this.getState();
    if (this.state && this.state.lastCommit) {
      this.insertCommitted(this.state.lastCommit);
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
    this.boxEl.textContent = "";
    this.preeditEl = null;
    this.exports.misstype_wasm_reset();
    this.updateState();
    this.render();
    this.boxEl?.focus();
  }

  setupDOM() {
    if (!this.container) return;
    this.container.innerHTML = `
      <div class="pg">
        <div class="field pg-box" id="pg-box" role="textbox" aria-multiline="true" aria-label="隨打注音試打區" spellcheck="false"></div>

        <div class="candidate-panel ${this.candidateOrientation}" id="pg-cand-panel" style="display: none;">
          <div class="candidate-list" id="pg-cand-list"></div>
          <div class="candidate-footer">
            <span class="candidate-title">候選字</span>
            <div class="candidate-page-nav">
              <button class="candidate-nav-btn" id="pg-cand-prev" title="上一頁 (PageUp)">‹</button>
              <span id="pg-cand-page">1/1</span>
              <button class="candidate-nav-btn" id="pg-cand-next" title="下一頁 (PageDown)">›</button>
            </div>
          </div>
        </div>

        <div class="pg-bar">
          <span><kbd>↓</kbd> 選字 · <kbd>Shift</kbd> 切換中英 · <kbd>Enter</kbd> 送字</span>
          <span class="pg-actions">
            <button class="pg-btn" id="pg-mode-btn" title="輕按 Shift 也能切換">中</button>
            <button class="pg-btn" id="pg-clear-btn">清空</button>
          </span>
        </div>
      </div>
    `;

    const q = (id) => this.container.querySelector(id);
    this.boxEl = q("#pg-box");
    this.preeditEl = null;
    this.boxEl.contentEditable = "plaintext-only";
    if (this.boxEl.contentEditable !== "plaintext-only") this.boxEl.contentEditable = "true";
    this.candidatePanel = q("#pg-cand-panel");
    this.candidateList = q("#pg-cand-list");
    this.candidatePageEl = q("#pg-cand-page");
    this.candPrevBtn = q("#pg-cand-prev");
    this.candNextBtn = q("#pg-cand-next");
    this.modeBtn = q("#pg-mode-btn");
    this.clearBtn = q("#pg-clear-btn");
  }

  showLoading(text) {
    this.boxEl.dataset.placeholder = text;
  }

  hideLoading() {
    this.boxEl.dataset.placeholder = "打字試試，例如 sucl";
  }

  // Committed text goes into the real editable at the composition spot (or the
  // caret), so selection, caret movement, paste and undo stay native.
  insertCommitted(text) {
    if (this.preeditEl && this.preeditEl.isConnected) {
      this.preeditEl.before(document.createTextNode(text));
    } else {
      this.boxEl.focus();
      document.execCommand("insertText", false, text);
    }
  }

  // Compose in place: the preedit is an inline, non-editable span at the caret.
  syncPreeditNode(has) {
    const sel = window.getSelection();
    if (has && !(this.preeditEl && this.preeditEl.isConnected)) {
      const span = document.createElement("span");
      span.className = "pg-preedit";
      span.contentEditable = "false";
      const range = sel.rangeCount && this.boxEl.contains(sel.anchorNode)
        ? sel.getRangeAt(0)
        : (() => { const r = document.createRange(); r.selectNodeContents(this.boxEl); r.collapse(false); return r; })();
      range.deleteContents();
      range.insertNode(span);
      this.preeditEl = span;
    } else if (!has && this.preeditEl) {
      const parent = this.preeditEl.parentNode;
      if (parent) {
        const at = Array.prototype.indexOf.call(parent.childNodes, this.preeditEl);
        this.preeditEl.remove();
        sel.collapse(parent, at);
      }
      this.preeditEl = null;
    }
    if (has) sel.collapse(this.preeditEl.parentNode, Array.prototype.indexOf.call(this.preeditEl.parentNode.childNodes, this.preeditEl) + 1);
  }

  // Moving the caret elsewhere ends the composition where it is.
  commitPending() {
    if (!this.ready || !this.state?.preedit) return;
    if (this.exports.misstype_wasm_commit() !== 0) {
      this.updateState();
      this.render();
    }
  }

  bindEvents() {
    if (!this.boxEl) return;

    // Panel and buttons must not steal focus, or the blur would end the composition.
    this.container.querySelectorAll(".candidate-panel, .pg-bar").forEach((el) => {
      el.addEventListener("mousedown", (e) => e.preventDefault());
    });
    this.boxEl.addEventListener("pointerdown", () => this.commitPending());
    this.boxEl.addEventListener("blur", () => this.commitPending());

    let shiftDownTime = 0;
    let shiftInterrupted = false;

    // Keydown handler
    this.boxEl.addEventListener("keydown", (e) => {
      if (e.isComposing || e.keyCode === 229) return;
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

      // Keys the decoder leaves alone (English mode, arrows, Enter with no
      // composition) fall through to the browser's own editing.
      if (this.sendKey(e.code, e.key, modifiers, 0)) e.preventDefault();
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
  }

  render() {
    if (!this.state) return;

    const preedit = this.state.preedit || "";
    this.syncPreeditNode(preedit.length > 0);

    if (preedit.length > 0) {
      const segments = (this.state.segments && this.state.segments.length > 0)
        ? this.state.segments
        : [[0, preedit.length]];
      const focus = this.state.focus || [0, preedit.length];

      let segHtml = "";
      for (const [start, end] of segments) {
        const text = preedit.substring(start, end);
        const isFocused = focus && start === focus[0] && end === focus[1];
        segHtml += `<span class="pg-seg ${isFocused ? "focused" : ""}">${escapeHtml(text)}</span>`;
      }
      this.preeditEl.innerHTML = segHtml;
    }

    // Candidate window rendering
    if (this.state.showsCandidates && this.state.candidates.length > 0) {
      this.candidatePanel.style.display = "block";
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
            <span class="candidate-text">${escapeHtml(cand)}</span>
            <span class="candidate-key">${keyLabel}</span>
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
        this.modeBtn.className = "pg-btn english";
      } else {
        this.modeBtn.textContent = "中";
        this.modeBtn.className = this.state.latinActive ? "pg-btn english" : "pg-btn";
      }
    }

    if (typeof this.onStateChange === "function") {
      this.onStateChange(this.state);
    }
  }

  positionCandidatePanel() {
    if (!this.preeditEl || !this.candidatePanel) return;
    const card = this.container.querySelector(".pg").getBoundingClientRect();
    const rect = this.preeditEl.getClientRects()[0] || this.preeditEl.getBoundingClientRect();
    const panelWidth = this.candidatePanel.offsetWidth || 200;
    const left = Math.min(Math.max(12, rect.left - card.left), Math.max(12, card.width - panelWidth - 16));
    this.candidatePanel.style.left = `${left}px`;
    this.candidatePanel.style.top = `${rect.bottom - card.top + 6}px`;
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
