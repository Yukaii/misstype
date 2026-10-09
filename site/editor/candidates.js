// The floating composition bar: pre-edit text, candidates, page controls.
// Same markup and look as the landing page playground (../playground.css).
const escapeHtml = (s) => s.replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#039;" }[c]));

export class CandidatePanel {
  constructor(root, { onPick, onPage }) {
    this.el = document.createElement("div");
    this.el.className = "candidate-panel";
    this.el.hidden = true;
    this.el.innerHTML = `
      <div class="candidate-list"></div>
      <div class="candidate-footer">
        <span class="candidate-title">候選字</span>
        <div class="candidate-page-nav">
          <button class="candidate-nav-btn" data-page="PageUp" type="button" aria-label="上一頁">‹</button>
          <span class="cp-page">1/1</span>
          <button class="candidate-nav-btn" data-page="PageDown" type="button" aria-label="下一頁">›</button>
        </div>
      </div>`;
    root.append(this.el);
    this.list = this.el.querySelector(".candidate-list");
    this.pageEl = this.el.querySelector(".cp-page");
    this.prev = this.el.querySelector('[data-page="PageUp"]');
    this.next = this.el.querySelector('[data-page="PageDown"]');
    // Taps must not move focus out of the editor, or the blur ends the composition.
    this.el.addEventListener("pointerdown", (e) => e.preventDefault());
    this.list.addEventListener("click", (e) => {
      const item = e.target.closest(".candidate-item");
      if (item) onPick(Number(item.dataset.index));
    });
    for (const b of [this.prev, this.next]) b.addEventListener("click", () => onPage(b.dataset.page));
  }

  setLayout(layout) {
    this.el.classList.toggle("horizontal", layout === "horizontal");
    this.el.classList.toggle("vertical", layout !== "horizontal");
  }

  setTheme(theme) {
    this.el.dataset.theme = theme;
  }

  hide() {
    this.el.hidden = true;
  }

  /** Draws `state` (the wasm session view); `rect` is the caret box on screen. */
  render(state, rect) {
    if (!state?.preedit) return this.hide();
    if (!(state.showsCandidates && state.candidates?.length > 0)) return this.hide();
    const keys = state.selectionKeys || [];
    this.prev.disabled = state.page === 0;
    this.next.disabled = state.page + 1 >= state.pageCount;
    this.pageEl.textContent = `${state.page + 1}/${state.pageCount}`;
    this.list.innerHTML = (state.pageCandidates || []).map((cand, i) => `
      <div class="candidate-item${i === state.pageSelected ? " selected" : ""}" data-index="${state.page * state.pageSize + i}">
        <span class="candidate-text">${escapeHtml(cand)}</span>
        <span class="candidate-key">${state.keysActive ? escapeHtml((keys[i] || String(i + 1)).toUpperCase()) : ""}</span>
      </div>`).join("");
    this.el.hidden = false;
    this.place(rect);
  }

  place(rect) {
    if (this.el.hidden || !rect) return;
    const vv = window.visualViewport;
    const left0 = vv?.offsetLeft || 0, top0 = vv?.offsetTop || 0;
    const width = vv?.width || innerWidth, height = vv?.height || innerHeight;
    const w = this.el.offsetWidth, h = this.el.offsetHeight;
    const left = Math.max(left0 + 8, Math.min(rect.left, left0 + width - w - 8));
    let top = rect.bottom + 8;
    if (top + h > top0 + height - 8) top = rect.top - h - 8;
    top = Math.max(top0 + 8, Math.min(top, top0 + height - h - 8));
    this.el.style.left = `${left}px`;
    this.el.style.top = `${top}px`;
  }
}
