// The floating composition bar: pre-edit text, candidates, page controls.
// Same markup and look as the landing page playground (../playground.css).
const escapeHtml = (s) => s.replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#039;" }[c]));

export class CandidatePanel {
  constructor(root, { onPick, onPage, bottomInset = () => 0 }) {
    this.bottomInset = bottomInset;
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

  /** Docked: one horizontally scrollable row just above the on-screen keyboard. */
  setDocked(docked) {
    this.docked = docked;
    this.el.classList.toggle("docked", docked);
    this.hide();
  }

  hide() {
    // The docked bar keeps its slot (empty) so the status strip above it does not jump.
    if (this.docked) this.list.textContent = "";
    this.el.hidden = !this.docked;
  }

  /** Draws `state` (the wasm session view); `rect` is the caret box on screen. */
  render(state, rect) {
    if (!state?.preedit) return this.hide();
    if (!(state.showsCandidates && state.candidates?.length > 0)) return this.hide();
    const keys = state.selectionKeys || [];
    this.prev.disabled = state.page === 0;
    this.next.disabled = state.page + 1 >= state.pageCount;
    this.pageEl.textContent = `${state.page + 1}/${state.pageCount}`;
    const base = state.page * state.pageSize;
    // Docked shows every candidate and scrolls; floating shows the current page.
    const items = this.docked ? state.candidates : (state.pageCandidates || []);
    const first = this.docked ? 0 : base;
    this.list.innerHTML = items.map((cand, i) => {
      const global = first + i, onPage = global - base;
      const selected = global === base + state.pageSelected;
      const key = state.keysActive && onPage >= 0 && onPage < state.pageSize ? (keys[onPage] || String(onPage + 1)).toUpperCase() : "";
      return `
      <div class="candidate-item${selected ? " selected" : ""}" data-index="${global}">
        <span class="candidate-text">${escapeHtml(cand)}</span>
        <span class="candidate-key">${escapeHtml(key)}</span>
      </div>`;
    }).join("");
    this.el.hidden = false;
    if (this.docked) this.list.querySelector(".selected")?.scrollIntoView({ inline: "nearest", block: "nearest" });
    this.place(rect);
  }

  place(rect) {
    if (this.el.hidden || !rect || this.docked) return;
    const vv = window.visualViewport;
    const left0 = vv?.offsetLeft || 0, top0 = vv?.offsetTop || 0;
    const width = vv?.width || innerWidth;
    // The on-screen keyboard covers the bottom of the layout viewport; stay above it.
    const height = (vv?.height || innerHeight) - this.bottomInset();
    this.el.style.maxHeight = `${Math.max(80, height - 16)}px`;
    const w = this.el.offsetWidth, h = this.el.offsetHeight;
    const left = Math.max(left0 + 8, Math.min(rect.left, left0 + width - w - 8));
    let top = rect.bottom + 8;
    if (top + h > top0 + height - 8) top = rect.top - h - 8;
    top = Math.max(top0 + 8, Math.min(top, top0 + height - h - 8));
    this.el.style.left = `${left}px`;
    this.el.style.top = `${top}px`;
  }
}
