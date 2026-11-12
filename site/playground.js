import MisstypeWasm from "../packages/misstype-wasm/src/index.js";
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
    this.englishUrl = options.englishUrl === undefined ? "english.tsv" : options.englishUrl;
    this.homophoneUrl = options.homophoneUrl || "homophone.bin";
    this.wordModelUrl = options.wordModelUrl || null;
    this.wordModelWeight = options.wordModelWeight ?? 0.5;
    this.wordModelLoaded = false;
    this.imeNoteText = options.imeNote || "";
    this.onStateChange = options.onStateChange || null;
    this.onReady = options.onReady;
    this.onError = options.onError;

    this.ime = null; // MisstypeWasm (packages/misstype-wasm)

    this.ready = false;
    this.state = null;
    this.candidateOrientation = options.candidateOrientation || "vertical"; // 'vertical' | 'horizontal'

    this.setupDOM();
    this.bindEvents();
  }

  getState() {
    return this.ime ? this.ime.state() : null;
  }

  async init() {
    this.showLoading("載入中，請稍候⋯");
    try {
      // Optional assets (toneless, English words, homophone table, the
      // experimental word model) degrade to "off" when missing.
      this.ime = await MisstypeWasm.load({
        wasmUrl: this.wasmUrl,
        lexiconUrl: this.lexiconUrl,
        tonelessUrl: this.tonelessUrl,
        englishUrl: this.englishUrl,
        homophoneUrl: this.homophoneUrl,
        wordModelUrl: this.wordModelUrl,
        wordModelWeight: this.wordModelWeight,
      });
      this.wordModelLoaded = this.ime.wordModelLoaded;
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
    if (this.state?.lastCommit) this.insertCommitted(this.ime.takeCommitted());
  }

  sendKey(code, keyText = "", modifiers = 0, phase = 0) {
    if (!this.ready) return false;
    const consumed = this.ime.key(code, keyText, modifiers, phase, Date.now() / 1000);
    this.updateState();
    this.render();
    return consumed;
  }

  toggleEnglish() {
    if (!this.ready) return;
    this.ime.toggleEnglish();
    this.updateState();
    this.render();
  }

  pickCandidate(index) {
    if (!this.ready) return;
    this.ime.pick(index);
    this.updateState();
    this.render();
    this.boxEl?.focus();
  }

  clear() {
    if (!this.ready) return;
    this.boxEl.textContent = "";
    this.preeditEl = null;
    this.ime.reset();
    this.updateState();
    this.render();
    this.boxEl?.focus();
  }

  setupDOM() {
    if (!this.container) return;
    this.container.innerHTML = `
      <div class="pg" data-theme="system">
        <div class="field pg-box" id="pg-box" role="textbox" aria-multiline="true" aria-label="隨打注音試打區" spellcheck="false"></div>

        <div class="pg-ime-note" id="pg-ime-note" role="status" hidden></div>

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
            <span class="pg-theme-control">
              <span class="pg-theme-label">主題</span>
              <button class="pg-theme-trigger" id="pg-theme-trigger" type="button" aria-haspopup="menu" aria-expanded="false">預設 <span aria-hidden="true">▾</span></button>
              <span class="pg-theme-menu" id="pg-theme-menu" role="menu" hidden>
                <button type="button" role="menuitem" data-theme="system">預設</button>
                <button type="button" role="menuitem" data-theme="solarized">Solarized</button>
                <button type="button" role="menuitem" data-theme="nord">Nord</button>
                <button type="button" role="menuitem" data-theme="gruvbox">Gruvbox</button>
                <button type="button" role="menuitem" data-theme="catppuccin">Catppuccin</button>
              </span>
            </span>
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
    this.imeNoteEl = q("#pg-ime-note");
    this.imeNoteEl.textContent = this.imeNoteText;
    this.candidatePanel = q("#pg-cand-panel");
    this.candidateList = q("#pg-cand-list");
    this.candidatePageEl = q("#pg-cand-page");
    this.candPrevBtn = q("#pg-cand-prev");
    this.candNextBtn = q("#pg-cand-next");
    this.modeBtn = q("#pg-mode-btn");
    this.clearBtn = q("#pg-clear-btn");
    this.themeTrigger = q("#pg-theme-trigger");
    this.themeMenu = q("#pg-theme-menu");
    this.themeName = "system";
  }

  setImeWarning(on) {
    if (!on) this.imeKeys = 0;
    if (!this.imeNoteText) return;
    this.boxEl.classList.toggle("ime-warning", on);
    this.imeNoteEl.hidden = !on;
  }

  showLoading(text) {
    this.boxEl.dataset.placeholder = text;
  }

  hideLoading() {
    this.boxEl.dataset.placeholder = "打字試試，例如 sucl";
  }

  editorRange() {
    const sel = window.getSelection();
    if (sel.rangeCount && this.boxEl.contains(sel.anchorNode) && this.boxEl.contains(sel.focusNode)) {
      return sel.getRangeAt(0).cloneRange();
    }
    const range = document.createRange();
    range.selectNodeContents(this.boxEl);
    range.collapse(false);
    return range;
  }

  // Preedit is temporary presentation. Restore the original selection before
  // making a browser editing transaction, so undo also restores replaced text.
  restorePreedit() {
    if (!this.preeditEl?.isConnected) return;
    const range = document.createRange();
    range.selectNode(this.preeditEl);
    range.deleteContents();
    const original = this.replacedContent;
    const first = original?.firstChild;
    const last = original?.lastChild;
    if (first) {
      range.insertNode(original);
      range.setStartBefore(first);
      range.setEndAfter(last);
    }
    this.preeditEl = null;
    this.replacedContent = null;
    const sel = window.getSelection();
    sel.removeAllRanges();
    sel.addRange(range);
  }

  insertCommitted(text) {
    this.restorePreedit();
    // insertText is deliberately used here: Range mutations do not enter the
    // browser's undo history. This is one transaction per decoder commit.
    this.insertingCommit = true;
    document.execCommand("insertText", false, text);
    this.insertingCommit = false;
  }

  syncPreeditNode(has) {
    if (has && !this.preeditEl?.isConnected) {
      const range = this.editorRange();
      this.replacedContent = range.extractContents();
      const span = document.createElement("span");
      span.className = "pg-preedit";
      span.contentEditable = "false";
      range.insertNode(span);
      this.preeditEl = span;
    } else if (!has) {
      this.restorePreedit();
    }
  }

  placeCompositionCaret() {
    if (!this.preeditEl) return;
    // The native caret remains outside the protected preedit. Its visual
    // position inside that span follows the core's UTF-16 syllable cursor.
    const sel = window.getSelection();
    const range = document.createRange();
    range.setStartAfter(this.preeditEl);
    range.collapse(true);
    sel.removeAllRanges();
    sel.addRange(range);
  }

  // Moving the caret elsewhere ends the composition where it is.
  commitPending() {
    if (!this.ready || !this.state?.preedit) return;
    if (this.ime.commit()) {
      this.updateState();
      this.render();
    }
  }

  bindEvents() {
    if (!this.boxEl) return;

    // Panel and buttons must not steal focus, or the blur would end the composition.
    this.container.querySelectorAll(".candidate-panel").forEach((el) => {
      el.addEventListener("mousedown", (e) => e.preventDefault());
    });
    this.boxEl.addEventListener("pointerdown", () => this.commitPending());
    this.boxEl.addEventListener("blur", () => {
      this.commitPending();
    });
    // Paste, cut, native IME input, and undo operate on committed document text.
    for (const type of ["paste", "cut", "compositionstart"]) {
      this.boxEl.addEventListener(type, () => this.commitPending());
    }
    this.boxEl.addEventListener("beforeinput", (e) => {
      if (!this.insertingCommit && this.state?.preedit) this.commitPending();
    });
    window.addEventListener("resize", () => this.positionCandidatePanel());
    window.addEventListener("scroll", () => this.positionCandidatePanel(), true);



    // Keydown handler
    this.boxEl.addEventListener("keydown", (e) => {
      // A system IME (Zhuyin, Pinyin...) takes the key before the decoder
      // does. The first key can slip through; a second means it is on.
      if (e.isComposing || e.keyCode === 229) {
        this.imeKeys = (this.imeKeys || 0) + 1;
        if (this.imeKeys >= 2) this.setImeWarning(true);
        return;
      }
      this.setImeWarning(false);
      const modifiers = (e.shiftKey ? 1 : 0) |
                        (e.ctrlKey ? 2 : 0) |
                        (e.altKey ? 4 : 0) |
                        (e.metaKey ? 8 : 0) |
                        (e.getModifierState("CapsLock") ? 16 : 0);

      // The browser owns document shortcuts; settle preedit before it copies,
      // replaces, or navigates text. Decoder Control+J/K remain available.
      if (e.metaKey || (e.ctrlKey && !["KeyJ", "KeyK"].includes(e.code))) {
        this.commitPending();
        return;
      }
      if (["Home", "End"].includes(e.code)) this.commitPending();

      // Keys the decoder leaves alone (English mode, arrows, Enter with no
      // composition) fall through to the browser's own editing.
      if (this.sendKey(e.code, e.key, modifiers, 0)) e.preventDefault();
    });

    this.boxEl.addEventListener("blur", () => this.setImeWarning(false));

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

    const themeLabels = { system: "預設", solarized: "Solarized", nord: "Nord", gruvbox: "Gruvbox", catppuccin: "Catppuccin" };
    const closeThemes = () => {
      this.themeMenu.hidden = true;
      this.themeTrigger.setAttribute("aria-expanded", "false");
    };
    this.themeTrigger?.addEventListener("click", (event) => {
      event.stopPropagation();
      this.themeMenu.hidden = !this.themeMenu.hidden;
      this.themeTrigger.setAttribute("aria-expanded", String(!this.themeMenu.hidden));
    });
    this.themeMenu?.querySelectorAll("[data-theme]").forEach((option) => option.addEventListener("click", (event) => {
      event.stopPropagation();
      this.themeName = option.dataset.theme;
      this.container.querySelector(".pg")?.setAttribute("data-theme", this.themeName);
      this.themeTrigger.innerHTML = `${themeLabels[this.themeName]} <span aria-hidden="true">▾</span>`;
      closeThemes();
      this.boxEl.focus();
    }));
    document.addEventListener("click", closeThemes);
    this.themeTrigger?.addEventListener("keydown", (event) => {
      if (event.key === "Escape") closeThemes();
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
      const focus = this.state.focus;

      let segHtml = "";
      for (const [start, end] of segments) {
        const text = preedit.substring(start, end);
        const isFocused = focus && start === focus[0] && end === focus[1];
        const caret = Math.max(0, Math.min(preedit.length, this.state.caret));
        const caretHtml = '<span class="pg-composition-caret" aria-hidden="true"></span>';
        let content = escapeHtml(text);
        if (caret >= start && (caret < end || (caret === end && end === preedit.length))) {
          content = escapeHtml(text.slice(0, caret - start)) + caretHtml + escapeHtml(text.slice(caret - start));
        }
        segHtml += `<span class="pg-seg ${isFocused ? "focused" : ""}">${content}</span>`;
      }
      this.preeditEl.innerHTML = segHtml;
      this.placeCompositionCaret();
    }

    this.boxEl.classList.toggle("composing", preedit.length > 0);

    // Candidate window rendering
    if (this.state.showsCandidates && this.state.candidates.length > 0) {
      this.candidatePanel.style.display = "block";
      this.candPrevBtn.disabled = this.state.page === 0;
      this.candNextBtn.disabled = this.state.page + 1 >= this.state.pageCount;
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
            <span class="candidate-key">${this.state.keysActive ? keyLabel : ""}</span>
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
    if (this.candidatePanel.style.display === "none") return;
    const anchor = this.preeditEl.querySelector(".pg-composition-caret");
    const rect = (anchor || this.preeditEl).getBoundingClientRect();
    const panelWidth = this.candidatePanel.offsetWidth;
    const panelHeight = this.candidatePanel.offsetHeight;
    const viewport = window.visualViewport;
    const leftEdge = viewport?.offsetLeft || 0;
    const topEdge = viewport?.offsetTop || 0;
    const width = viewport?.width || window.innerWidth;
    const height = viewport?.height || window.innerHeight;
    const left = Math.max(leftEdge + 8, Math.min(rect.left, leftEdge + width - panelWidth - 8));
    let top = rect.bottom + 8;
    if (top + panelHeight > topEdge + height - 8) top = rect.top - panelHeight - 8;
    top = Math.max(topEdge + 8, Math.min(top, topEdge + height - panelHeight - 8));
    this.candidatePanel.style.left = `${left}px`;
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
