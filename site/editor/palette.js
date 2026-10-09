// Command palette: a filterable list of everything the editor can do.
// `commands` is an array of { id, title, keywords?, chord?, run }.
export class Palette {
  constructor(getCommands) {
    this.getCommands = getCommands;
    this.dialog = document.createElement("dialog");
    this.dialog.className = "palette";
    this.dialog.innerHTML = `
      <input class="palette-input" type="text" role="combobox" aria-expanded="true" aria-controls="palette-list"
        placeholder="輸入指令…" autocomplete="off" autocapitalize="off" spellcheck="false">
      <ul class="palette-list" id="palette-list" role="listbox"></ul>`;
    document.body.append(this.dialog);
    this.input = this.dialog.querySelector("input");
    this.listEl = this.dialog.querySelector("ul");
    this.items = [];
    this.index = 0;
    this.input.addEventListener("input", () => this.filter());
    this.dialog.addEventListener("keydown", (e) => this.onKey(e));
    // A tap outside the card closes it (the ::backdrop belongs to the dialog).
    this.dialog.addEventListener("pointerdown", (e) => { if (e.target === this.dialog) this.close(); });
    this.listEl.addEventListener("click", (e) => {
      const li = e.target.closest("li[data-i]");
      if (li) this.run(Number(li.dataset.i));
    });
    this.dialog.addEventListener("close", () => this.onClose?.());
  }

  get isOpen() {
    return this.dialog.open;
  }

  open() {
    if (this.isOpen) return;
    this.commands = this.getCommands();
    this.input.value = "";
    this.filter();
    this.dialog.showModal();
    this.input.focus();
  }

  close() {
    if (this.isOpen) this.dialog.close();
  }

  filter() {
    const terms = this.input.value.toLowerCase().split(/\s+/).filter(Boolean);
    this.items = this.commands.filter((c) => {
      if (c.when && !c.when()) return false;
      const hay = `${c.title} ${c.keywords || ""}`.toLowerCase();
      return terms.every((t) => hay.includes(t));
    });
    this.index = 0;
    this.draw();
  }

  draw() {
    this.listEl.innerHTML = this.items.length
      ? this.items.map((c, i) => `
        <li role="option" data-i="${i}" aria-selected="${i === this.index}" class="${i === this.index ? "active" : ""}">
          <span class="palette-title">${escapeHtml(c.title)}</span>
          ${c.chord ? `<kbd>${escapeHtml(c.chord)}</kbd>` : ""}
        </li>`).join("")
      : `<li class="palette-empty">沒有符合的指令</li>`;
    this.listEl.querySelector(".active")?.scrollIntoView({ block: "nearest" });
  }

  move(delta) {
    if (!this.items.length) return;
    this.index = (this.index + delta + this.items.length) % this.items.length;
    this.draw();
  }

  run(i) {
    const command = this.items[i];
    if (!command) return;
    this.close();
    // Let the dialog hand focus back to the editor before the command runs.
    queueMicrotask(() => command.run());
  }

  onKey(e) {
    if (e.isComposing) return;
    if (e.key === "ArrowDown" || (e.ctrlKey && e.key === "n")) { e.preventDefault(); this.move(1); }
    else if (e.key === "ArrowUp" || (e.ctrlKey && e.key === "p")) { e.preventDefault(); this.move(-1); }
    else if (e.key === "Enter") { e.preventDefault(); this.run(this.index); }
  }
}

const escapeHtml = (s) => s.replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#039;" }[c]));
