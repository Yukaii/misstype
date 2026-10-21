// The notes sidebar: folders (one level) and notes, a ⋯ menu on each row,
// drag a note onto a folder or another note to move it. It edits the store
// (notes.js) itself; opening and deleting notes go through the editor, which
// has to save or swap the document first.
import { UNTITLED } from "./notes.js";

const escapeHtml = (s) => s.replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#039;" }[c]));

const ICON = {
  note: '<svg viewBox="0 0 16 16" aria-hidden="true"><path d="M8 3.5v9M3.5 8h9"/></svg>',
  folder: '<svg viewBox="0 0 16 16" aria-hidden="true"><path d="M2.5 4.5a1 1 0 0 1 1-1h2.6l1.4 1.5h5a1 1 0 0 1 1 1v5.5a1 1 0 0 1-1 1h-9a1 1 0 0 1-1-1z"/><path d="M8 7v3.4M6.3 8.7h3.4"/></svg>',
  chevron: '<svg class="chev" viewBox="0 0 16 16" aria-hidden="true"><path d="M6 4l4 4-4 4"/></svg>',
  more: '<svg viewBox="0 0 16 16" aria-hidden="true"><circle cx="3.6" cy="8" r=".9"/><circle cx="8" cy="8" r=".9"/><circle cx="12.4" cy="8" r=".9"/></svg>',
};

export class Sidebar {
  /**
   * @param {HTMLElement} el
   * @param {{ notes: ReturnType<import("./notes.js").createNotes>, current: () => string, open: (id: string) => void,
   *   create: (folder: string|null) => void, remove: (id: string) => void, toast: (m: string) => void }} hooks
   */
  constructor(el, hooks) {
    this.el = el;
    this.hooks = hooks;
    this.notes = hooks.notes;
    this.el.innerHTML = `
      <div class="side-head">
        <span class="side-title">筆記</span>
        <button class="side-btn" type="button" data-side="new-folder" aria-label="新增資料夾" title="新增資料夾">${ICON.folder}</button>
        <button class="side-btn" type="button" data-side="new-note" aria-label="新增筆記" title="新增筆記">${ICON.note}</button>
      </div>
      <ul class="tree" role="tree" aria-label="筆記"></ul>
      <div class="side-foot"><button class="status-link" type="button" data-side="para">建立 PARA 資料夾</button></div>`;
    this.tree = el.querySelector(".tree");
    this.foot = el.querySelector(".side-foot");
    this.menu = Object.assign(document.createElement("div"), { className: "side-menu", hidden: true });
    this.menu.setAttribute("role", "menu");
    document.body.append(this.menu);

    el.addEventListener("click", (e) => this.onClick(e));
    this.menu.addEventListener("click", (e) => this.onMenu(e));
    document.addEventListener("pointerdown", (e) => {
      if (!this.menu.hidden && !this.menu.contains(e.target) && !e.target.closest("[data-more]")) this.closeMenu();
    }, true);
    document.addEventListener("keydown", (e) => {
      if (e.key === "Escape" && !this.menu.hidden) { e.preventDefault(); e.stopPropagation(); this.closeMenu(true); }
    }, true);
    this.wireDrag();
  }

  render() {
    const index = this.notes.load();
    // This tab's note: the stored "current" is whichever tab opened one last.
    const current = this.hooks.current();
    const row = (note) => `
      <li class="note${note.id === current ? " current" : ""}" role="treeitem" data-note="${note.id}" draggable="true"
        ${note.id === current ? 'aria-current="page"' : ""}>
        <div class="row">
          <button class="row-main" type="button" data-open="${note.id}"><span class="name${note.title ? "" : " untitled"}">${escapeHtml(note.title || UNTITLED)}</span></button>
          <button class="row-more" type="button" data-more="note" data-id="${note.id}" aria-label="筆記選項" aria-haspopup="menu">${ICON.more}</button>
        </div>
      </li>`;
    const folders = index.folders.map((folder) => {
      const inside = index.notes.filter((n) => n.folder === folder.id);
      return `
        <li class="folder${folder.open ? " open" : ""}" role="treeitem" aria-expanded="${folder.open}" data-folder="${folder.id}">
          <div class="row">
            <button class="row-main" type="button" data-toggle="${folder.id}">${ICON.chevron}<span class="name">${escapeHtml(folder.name)}</span><span class="n">${inside.length || ""}</span></button>
            <button class="row-more" type="button" data-more="folder" data-id="${folder.id}" aria-label="資料夾選項" aria-haspopup="menu">${ICON.more}</button>
          </div>
          ${folder.open ? `<ul role="group">${inside.map(row).join("")}</ul>` : ""}
        </li>`;
    }).join("");
    const loose = index.notes.filter((n) => !n.folder || !index.folders.some((f) => f.id === n.folder));
    this.tree.innerHTML = folders + loose.map(row).join("");
    this.foot.hidden = index.folders.length > 0;
  }

  /** Scrolls the open note's row into view (after switching notes from elsewhere). */
  reveal() {
    this.tree.querySelector(".note.current")?.scrollIntoView({ block: "nearest" });
  }

  onClick(e) {
    const t = e.target.closest("button, input");
    if (!t || t.tagName === "INPUT") return;
    if (t.dataset.open) this.hooks.open(t.dataset.open);
    else if (t.dataset.toggle) { this.notes.toggleFolder(t.dataset.toggle); this.render(); }
    else if (t.dataset.more) this.openMenu(t);
    else if (t.dataset.side === "new-note") this.hooks.create(null);
    else if (t.dataset.side === "new-folder") this.newFolder();
    else if (t.dataset.side === "para") this.addPara();
  }

  newFolder() {
    const id = this.notes.createFolder("新資料夾");
    this.render();
    this.rename(id);
  }

  addPara() {
    const added = this.notes.addPara();
    this.render();
    this.hooks.toast(added ? `已建立 ${added} 個 PARA 資料夾` : "PARA 資料夾都已經有了");
  }

  /** Swaps a folder's name for a text field; Enter or leaving it saves, Esc cancels. */
  rename(id) {
    const button = this.tree.querySelector(`[data-folder="${id}"] .row-main`);
    if (!button) return;
    const name = button.querySelector(".name").textContent;
    const input = Object.assign(document.createElement("input"), { className: "rename", value: name, type: "text" });
    input.setAttribute("aria-label", "資料夾名稱");
    input.spellcheck = false;
    button.replaceWith(input);
    input.focus();
    input.select();
    let done = false;
    const finish = (save) => {
      if (done) return;
      done = true;
      if (save) this.notes.renameFolder(id, input.value);
      this.render();
    };
    input.addEventListener("keydown", (e) => {
      e.stopPropagation();
      if (e.isComposing) return;
      if (e.key === "Enter") { e.preventDefault(); finish(true); }
      else if (e.key === "Escape") { e.preventDefault(); finish(false); }
    });
    input.addEventListener("blur", () => finish(true));
  }

  openMenu(button) {
    const index = this.notes.load();
    const { id, more } = button.dataset;
    let items;
    if (more === "note") {
      const note = index.notes.find((n) => n.id === id);
      if (!note) return;
      const targets = [{ id: "", name: "最上層" }, ...index.folders].filter((f) => (f.id || null) !== (note.folder || null));
      items = [
        ...targets.map((f) => `<button type="button" role="menuitem" data-act="move" data-to="${f.id}">移到「${escapeHtml(f.name)}」</button>`),
        '<hr>',
        '<button type="button" role="menuitem" class="danger" data-act="delete-note">刪除筆記</button>',
      ];
    } else {
      items = [
        '<button type="button" role="menuitem" data-act="new-here">在這裡新增筆記</button>',
        '<button type="button" role="menuitem" data-act="rename">重新命名</button>',
        '<hr>',
        '<button type="button" role="menuitem" class="danger" data-act="delete-folder">刪除資料夾</button>',
      ];
    }
    this.menu.innerHTML = items.join("");
    this.menu.dataset.id = id;
    this.menuButton?.removeAttribute("aria-expanded");
    this.menuButton = button;
    button.setAttribute("aria-expanded", "true");
    this.menu.hidden = false;
    const r = button.getBoundingClientRect();
    const w = this.menu.offsetWidth;
    const h = this.menu.offsetHeight;
    this.menu.style.left = `${Math.max(8, Math.min(r.right - w, innerWidth - w - 8))}px`;
    this.menu.style.top = `${r.bottom + h + 8 > innerHeight ? Math.max(8, r.top - h - 4) : r.bottom + 4}px`;
    this.menu.querySelector("button")?.focus({ preventScroll: true });
  }

  closeMenu(refocus = false) {
    this.menu.hidden = true;
    this.menuButton?.removeAttribute("aria-expanded");
    if (refocus) this.menuButton?.focus({ preventScroll: true });
  }

  onMenu(e) {
    const t = e.target.closest("button[data-act]");
    if (!t) return;
    const { id } = this.menu.dataset;
    this.closeMenu();
    switch (t.dataset.act) {
      case "move": this.notes.move(id, t.dataset.to || null); this.render(); break;
      case "delete-note": this.hooks.remove(id); break;
      case "new-here": this.hooks.create(id); break;
      case "rename": this.rename(id); break;
      case "delete-folder": {
        const name = this.notes.load().folders.find((f) => f.id === id)?.name ?? "";
        this.notes.deleteFolder(id);
        this.render();
        this.hooks.toast(`已刪除資料夾「${name}」，裡面的筆記移到最上層`);
        break;
      }
    }
  }

  /** Drop on a note: move before it (into its folder). On a folder row: into it. On the rest of the list: top level. */
  wireDrag() {
    let dragged = null;
    const clear = () => this.tree.querySelectorAll(".drop-before, .drop-into").forEach((n) => n.classList.remove("drop-before", "drop-into"));
    const target = (e) => {
      const note = e.target.closest("li.note");
      if (note) return { el: note, cls: "drop-before", folder: note.parentElement.closest("li.folder")?.dataset.folder ?? null, before: note.dataset.note };
      const folder = e.target.closest("li.folder");
      if (folder) return { el: folder, cls: "drop-into", folder: folder.dataset.folder, before: null };
      return { el: null, folder: null, before: null };
    };
    this.tree.addEventListener("dragstart", (e) => {
      const li = e.target.closest?.("li.note");
      if (!li) return;
      dragged = li.dataset.note;
      e.dataTransfer.effectAllowed = "move";
      e.dataTransfer.setData("text/plain", li.textContent.trim());
      li.classList.add("dragging");
    });
    this.tree.addEventListener("dragend", () => { dragged = null; clear(); this.tree.querySelector(".dragging")?.classList.remove("dragging"); });
    this.el.addEventListener("dragover", (e) => {
      if (!dragged) return;
      e.preventDefault();
      clear();
      const t = target(e);
      if (t.el && t.before !== dragged) t.el.classList.add(t.cls);
    });
    this.el.addEventListener("drop", (e) => {
      if (!dragged) return;
      e.preventDefault();
      const t = target(e);
      this.notes.move(dragged, t.folder, t.before);
      if (t.folder) this.notes.toggleFolder(t.folder, true);
      dragged = null;
      this.render();
    });
  }
}
