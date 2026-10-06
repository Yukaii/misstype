import { WASI } from "@bjorn3/browser_wasi_shim";

/**
 * Misstype WebAssembly IME Playground Engine & UI Controller
 */
export class MisstypePlayground {
  constructor(options = {}) {
    this.container = options.container || document.querySelector(".playground-container");
    this.wasmUrl = options.wasmUrl || "misstype.wasm";
    this.lexiconUrl = options.lexiconUrl || "lexicon.tsv";
    this.tonelessUrl = options.tonelessUrl || "toneless.tsv";

    this.instance = null;
    this.exports = null;
    this.memory = null;
    this.wasi = null;
    this.ready = false;

    this.committedText = "";
    this.state = null;

    // DOM Elements
    this.boxEl = null;
    this.preeditEl = null;
    this.committedEl = null;
    this.caretEl = null;
    this.candidatePanel = null;
    this.modeBtn = null;
    this.loadingMask = null;
    this.loadingText = null;
  }

  async init() {
    this.setupDOM();
    this.showLoading("正在載入 WebAssembly 核心與詞庫...");

    try {
      this.wasi = new WASI([], [], []);
      const wasiImport = { wasi_snapshot_preview1: this.wasi.wasiImport };

      // Load WASM and dictionary files concurrently
      this.showLoading("下載組件 (WASM & 15萬詞庫)...");
      const [wasmResponse, lexiconText, tonelessText] = await Promise.all([
        fetch(this.wasmUrl),
        fetch(this.lexiconUrl).then(r => r.text()),
        fetch(this.tonelessUrl).then(r => r.text()).catch(() => "")
      ]);

      this.showLoading("編譯 WebAssembly 模組...");
      const wasmBytes = await wasmResponse.arrayBuffer();
      const { instance } = await WebAssembly.instantiate(wasmBytes, wasiImport);
      this.instance = instance;
      this.exports = instance.exports;
      this.memory = instance.exports.memory;
      this.wasi.start(instance);

      this.showLoading("載入注音聲調與語言模型...");
      const lexBuf = this.writeString(lexiconText);
      const toneBuf = this.writeString(tonelessText);

      this.exports.misstype_wasm_init(lexBuf.ptr, lexBuf.len, toneBuf.ptr, toneBuf.len);
      this.exports.misstype_wasm_free(lexBuf.ptr);
      this.exports.misstype_wasm_free(toneBuf.ptr);

      this.ready = true;
      this.hideLoading();

      this.updateState();
      this.render();
      this.bindEvents();
    } catch (err) {
      console.error("[MisstypePlayground] Initialization failed:", err);
      this.showLoading(`載入失敗: ${err.message}`);
    }
  }

  writeString(str) {
    const enc = new TextEncoder();
    const bytes = enc.encode(str);
    const ptr = this.exports.misstype_wasm_alloc(bytes.length);
    new Uint8Array(this.memory.buffer, ptr, bytes.length).set(bytes);
    return { ptr, len: bytes.length };
  }

  updateState() {
    if (!this.ready) return;
    const ptr = this.exports.misstype_wasm_get_state_json();
    const u8 = new Uint8Array(this.memory.buffer);
    let end = ptr;
    while (u8[end] !== 0) end++;
    const jsonStr = new TextDecoder().decode(u8.subarray(ptr, end));
    this.state = JSON.parse(jsonStr);

    if (this.state.lastCommit) {
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
          <span class="playground-placeholder" id="pg-placeholder">請在此點擊並以鍵盤直接打字（免打聲調、打錯字試試看）...</span>
        </div>

        <!-- Floating candidate panel (選字介面) -->
        <div class="candidate-panel hidden" id="pg-cand-panel">
          <ul class="candidate-list" id="pg-cand-list"></ul>
          <div class="candidate-footer">
            <span id="pg-cand-page">1 / 1</span>
            <div class="candidate-page-nav">
              <button class="candidate-nav-btn" id="pg-cand-prev" title="上一頁 (PageUp 或 [)">‹</button>
              <button class="candidate-nav-btn" id="pg-cand-next" title="下一頁 (PageDown 或 ])">›</button>
            </div>
          </div>
        </div>

        <div class="playground-footer">
          <div class="playground-tips">
            <span>提示：</span>
            <span><kbd>↓</kbd> 展開選字</span>
            <span><kbd>A</kbd>~<kbd>K</kbd> 直接選字</span>
            <span><kbd>Space</kbd> / <kbd>Return</kbd> 上字</span>
            <span><kbd>Shift</kbd> 切換中英</span>
          </div>
          <div class="playground-actions">
            <span style="font-size: 12px; color: var(--muted);">純本地 WebAssembly 運算</span>
          </div>
        </div>

        <div class="playground-loading-mask" id="pg-loading">
          <div class="playground-spinner"></div>
          <div class="playground-loading-text" id="pg-loading-text">正在初始化...</div>
        </div>
      </div>

      <div class="playground-presets">
        <span class="presets-label">快速體驗：</span>
        <button class="preset-chip" data-keys="ru0tu8tu8gu;c0cj">免打聲調（今天天氣很好）</button>
        <button class="preset-chip" data-keys="u;ru0tu8tu8gu;c0cj">順序打反（ㄧㄐㄢ 今天天氣很好）</button>
        <button class="preset-chip" data-keys="1ejiu8h0d3r/628u.3">漏打符號（明天早上九點開會）</button>
        <button class="preset-chip" data-keys="xuxudub/b/">按到隔壁鍵（謝謝你幫忙）</button>
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

    // Keydown handler
    this.boxEl.addEventListener("keydown", (e) => {
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
      }
    });

    // Mode toggle button click
    this.modeBtn?.addEventListener("click", (e) => {
      e.stopPropagation();
      this.sendKey("ShiftLeft", "Shift", 0, 0);
      this.sendKey("ShiftLeft", "Shift", 0, 1);
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
      // Build segmented spans
      const segments = this.state.segments || [];
      const focus = this.state.focus;

      if (segments.length > 0) {
        let segHtml = "";
        let cursorInserted = false;

        for (let i = 0; i < segments.length; i++) {
          const [start, end] = segments[i];
          const isFocused = focus && focus[0] === start && focus[1] === end;
          const segClass = isFocused ? "text-segment focused" : "text-segment";
          const segText = preedit.substring(start, end);

          // If caret falls within this segment
          if (!cursorInserted && caretPos >= start && caretPos <= end) {
            const before = segText.substring(0, caretPos - start);
            const after = segText.substring(caretPos - start);
            segHtml += `<span class="${segClass}">${escapeHtml(before)}</span>`;
            segHtml += `<span class="playground-caret"></span>`;
            segHtml += `<span class="${segClass}">${escapeHtml(after)}</span>`;
            cursorInserted = true;
          } else {
            segHtml += `<span class="${segClass}">${escapeHtml(segText)}</span>`;
          }
        }

        if (!cursorInserted) {
          segHtml += `<span class="playground-caret"></span>`;
        }
        this.preeditEl.innerHTML = segHtml;
        this.caretEl.style.display = "none";
      } else {
        const before = preedit.substring(0, caretPos);
        const after = preedit.substring(caretPos);
        this.preeditEl.innerHTML = `<span class="text-segment">${escapeHtml(before)}</span><span class="playground-caret"></span><span class="text-segment">${escapeHtml(after)}</span>`;
        this.caretEl.style.display = "none";
      }
    } else {
      this.preeditEl.innerHTML = "";
      this.caretEl.style.display = "inline-block";
    }

    // Mode button
    if (this.modeBtn) {
      if (this.state.english) {
        this.modeBtn.textContent = "英";
        this.modeBtn.className = "mode-toggle-btn english";
      } else {
        this.modeBtn.textContent = this.state.latinActive ? "英(暫)" : "中";
        this.modeBtn.className = this.state.latinActive ? "mode-toggle-btn english" : "mode-toggle-btn";
      }
    }

    // Candidate Window (選字介面)
    this.renderCandidatePanel();
  }

  renderCandidatePanel() {
    if (!this.candidatePanel) return;

    const showsCandidates = this.state.showsCandidates &&
                            this.state.candidates &&
                            this.state.candidates.length > 0;

    if (!showsCandidates) {
      this.candidatePanel.classList.add("hidden");
      return;
    }

    this.candidatePanel.classList.remove("hidden");

    // Position the panel relative to the preedit / box
    const boxRect = this.boxEl.getBoundingClientRect();
    const containerRect = this.container.getBoundingClientRect();

    // Find the caret element or preedit element to anchor to
    const activeCaret = this.container.querySelector(".playground-caret") || this.caretEl;
    let top = 140;
    let left = 24;

    if (activeCaret) {
      const caretRect = activeCaret.getBoundingClientRect();
      top = caretRect.bottom - containerRect.top + 8;
      left = Math.max(12, caretRect.left - containerRect.left);
    } else {
      top = boxRect.bottom - containerRect.top + 8;
    }

    // Keep panel within right edge
    const maxLeft = containerRect.width - 240;
    if (left > maxLeft && maxLeft > 12) {
      left = maxLeft;
    }

    this.candidatePanel.style.top = `${top}px`;
    this.candidatePanel.style.left = `${left}px`;

    // Render candidate rows
    const pageCandidates = this.state.pageCandidates || [];
    const selectionKeys = this.state.selectionKeys || [];
    const pageSelected = this.state.pageSelected;
    const page = this.state.page;
    const pageSize = this.state.pageSize;

    this.candidateList.innerHTML = pageCandidates.map((cand, i) => {
      const isSelected = (i === pageSelected);
      const selClass = isSelected ? "candidate-item selected" : "candidate-item";
      const keyLabel = selectionKeys[i] ? selectionKeys[i].toUpperCase() : `${i + 1}`;
      const globalIdx = page * pageSize + i;

      return `
        <li class="${selClass}" data-index="${globalIdx}">
          <span class="candidate-text">${escapeHtml(cand)}</span>
          <span class="candidate-key">${escapeHtml(keyLabel)}</span>
        </li>
      `;
    }).join("");

    // Add click listeners to candidate rows
    this.candidateList.querySelectorAll(".candidate-item").forEach(item => {
      item.addEventListener("click", (e) => {
        e.stopPropagation();
        const idx = parseInt(item.dataset.index, 10);
        this.pickCandidate(idx);
      });
    });

    // Page indicator and navigation
    if (this.candidatePageEl) {
      this.candidatePageEl.textContent = `${this.state.page + 1} / ${this.state.pageCount}`;
    }
    if (this.candPrevBtn) {
      this.candPrevBtn.disabled = (this.state.page <= 0);
    }
    if (this.candNextBtn) {
      this.candNextBtn.disabled = (this.state.page >= this.state.pageCount - 1);
    }
  }
}

function escapeHtml(str) {
  return (str || "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&#039;");
}
