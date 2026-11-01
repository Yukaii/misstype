// The editor's notes: an index (folders, note order, titles, which note is
// open) plus one localStorage key per note body, so typing rewrites only the
// note being edited. Folders are one level deep (enough for PARA: Projects,
// Areas, Resources, Archives); a note sits in a folder or at the top level.
//
// Every change reads the index afresh, edits it and writes it back, so a
// second tab (or the installed app next to a Safari tab) does not wipe out
// notes the other one created.

import { generateKeyBetween } from "fractional-indexing";

const INDEX_KEY = "misstype-editor-notes";
const BODY_KEY = (id) => `misstype-editor-note:${id}`;
/** The single note of earlier versions; becomes the first note. */
const LEGACY_KEY = "misstype-editor-md";

export const PARA = ["Projects", "Areas", "Resources", "Archives"];
export const UNTITLED = "未命名";

const newId = () => Date.now().toString(36) + Math.random().toString(36).slice(2, 7);
const orderBetween = (a, b) => generateKeyBetween(a || null, b || null);

// Fractional-index keys compare as ASCII; localeCompare would order "a0"
// before "Zz" (case-insensitive), which is the opposite of their intent.
const byOrder = (a, b) => {
  const ao = a.order || "";
  const bo = b.order || "";
  if (ao !== bo) return ao < bo ? -1 : 1;
  return a.id < b.id ? -1 : a.id > b.id ? 1 : 0;
};

/**
 * Places `note` between two order keys. Two devices can independently make
 * the same key (both inserting at the top of an empty folder), so an
 * impossible pair falls back to re-spacing that folder in array order.
 * Returns every note whose key changed, for the workspace mirror.
 */
function place(index, note, previous, next) {
  try {
    note.order = generateKeyBetween(previous, next);
    return [{ id: note.id, folder: note.folder, order: note.order }];
  } catch {
    const changed = [];
    let order = null;
    for (const other of index.notes) {
      if (other.folder !== note.folder) continue;
      order = generateKeyBetween(order, null);
      other.order = order;
      changed.push({ id: other.id, folder: other.folder, order });
    }
    return changed;
  }
}

/** Gives old indexes an order key per folder/note, preserving their array order. */
function ensureOrders(index) {
  let changed = false;
  let previous = null;
  for (const folder of index.folders) {
    if (!folder.order) {
      folder.order = generateKeyBetween(previous, null);
      changed = true;
    }
    previous = folder.order;
  }
  previous = null;
  for (const note of index.notes) {
    if (!note.order) {
      note.order = generateKeyBetween(previous, null);
      changed = true;
    }
    previous = note.order;
  }
  return changed;
}

/** First line of text with Markdown block markers stripped, or "" for an empty note. */
export function titleOf(markdown) {
  for (const raw of markdown.split("\n")) {
    const line = raw
      .replace(/^\s*(?:#{1,6}\s+|>\s*|[-*+]\s+(?:\[[ xX]\]\s+)?|\d+[.)]\s+|```\S*)*/, "")
      .replace(/[*_`~]/g, "")
      .replace(/&nbsp;/g, "")
      .trim();
    if (line) return line.length > 60 ? `${line.slice(0, 60)}…` : line;
  }
  return "";
}

/**
 * `onChange` hears every change to what is stored (not which note is open or
 * which folders are expanded). `onWorkspace` hears the organization edits
 * (folders, note placement and order) that workspace.js mirrors into its CRDT.
 */
export function createNotes(storage = globalThis.localStorage, { onChange = () => {}, onWorkspace = () => {} } = {}) {
  const get = (key) => {
    try { return storage.getItem(key); } catch { return null; }
  };
  const set = (key, value) => {
    try { storage.setItem(key, value); return true; } catch { return false; /* storage full or private mode */ }
  };
  const remove = (key) => {
    try { storage.removeItem(key); } catch { /* private mode */ }
  };

  function load() {
    let index = null;
    try { index = JSON.parse(get(INDEX_KEY)); } catch { /* damaged: start over below */ }
    if (index && Array.isArray(index.notes) && Array.isArray(index.folders)) {
      if (!index.notes.length) index.notes.push(blankNote(null));
      if (!index.notes.some((n) => n.id === index.current)) index.current = index.notes[0].id;
      if (ensureOrders(index)) set(INDEX_KEY, JSON.stringify(index));
      return index;
    }
    // First visit, or an earlier version's single note.
    const legacy = get(LEGACY_KEY) || "";
    const note = { ...blankNote(null), title: titleOf(legacy) };
    index = { v: 1, current: note.id, folders: [], notes: [note] };
    ensureOrders(index);
    if (legacy) set(BODY_KEY(note.id), legacy);
    if (set(INDEX_KEY, JSON.stringify(index)) && legacy) remove(LEGACY_KEY);
    return index;
  }

  const blankNote = (folder) => ({ id: newId(), folder, title: "", updated: Date.now(), order: null });

  /** Applies `edit` to a fresh copy of the index and stores it; returns edit's result. */
  function change(edit, notify = true) {
    const index = load();
    const result = edit(index);
    set(INDEX_KEY, JSON.stringify(index));
    if (notify) onChange();
    return result;
  }

  return {
    load,
    read: (id) => get(BODY_KEY(id)) || "",

    /** Saves a note body; its title follows the first line. Returns true if the title changed. */
    write(id, markdown) {
      set(BODY_KEY(id), markdown);
      return change((index) => {
        const note = index.notes.find((n) => n.id === id);
        if (!note) return false;
        const title = titleOf(markdown);
        note.updated = Date.now();
        if (note.title === title) return false;
        note.title = title;
        return true;
      });
    },

    setCurrent: (id) => change((index) => { index.current = id; }, false),

    /** A new note at the top of `folder` (null: top level); returns its id. */
    create(folder = null, markdown = "") {
      const note = change((index) => {
        const known = index.folders.some((f) => f.id === folder) ? folder : null;
        const first = index.notes.find((n) => n.folder === known);
        const created = { ...blankNote(known), title: titleOf(markdown), order: orderBetween(null, first?.order) };
        if (markdown) set(BODY_KEY(created.id), markdown);
        index.notes.unshift(created);
        index.current = created.id;
        const parent = index.folders.find((f) => f.id === created.folder);
        if (parent) parent.open = true;
        return created;
      });
      onWorkspace({ type: "note", id: note.id, folder: note.folder, order: note.order });
      return note.id;
    },

    /** Deletes a note; returns the id that is open afterwards. */
    delete(id) {
      remove(BODY_KEY(id));
      let created = null;
      const current = change((index) => {
        const at = index.notes.findIndex((n) => n.id === id);
        if (at < 0) return index.current;
        const { folder } = index.notes[at];
        index.notes.splice(at, 1);
        if (index.current === id) {
          // A neighbour in the same folder, else anything, else a fresh note.
          const next = index.notes.find((n, i) => n.folder === folder && i >= at)
            || [...index.notes].reverse().find((n) => n.folder === folder)
            || index.notes[0];
          if (next) index.current = next.id;
          else {
            const note = blankNote(null);
            note.order = orderBetween(null, null);
            index.notes.push(note);
            index.current = note.id;
            created = note;
          }
        }
        return index.current;
      });
      onWorkspace({ type: "noteDelete", id });
      if (created) onWorkspace({ type: "note", id: created.id, folder: created.folder, order: created.order });
      return current;
    },

    /** Moves a note into `folder` (null: top level), before note `before` or at the folder's top. */
    move(id, folder, before = null) {
      const changed = change((index) => {
        const at = index.notes.findIndex((n) => n.id === id);
        if (at < 0 || id === before) return null;
        const [note] = index.notes.splice(at, 1);
        note.folder = index.folders.some((f) => f.id === folder) ? folder : null;
        let to = before ? index.notes.findIndex((n) => n.id === before) : -1;
        if (to < 0) to = index.notes.findIndex((n) => n.folder === note.folder);
        const at2 = to < 0 ? index.notes.length : to;
        index.notes.splice(at2, 0, note);
        let previous = null;
        let next = null;
        for (let i = at2 - 1; i >= 0; i--) if (index.notes[i].folder === note.folder) { previous = index.notes[i].order; break; }
        for (let i = at2 + 1; i < index.notes.length; i++) if (index.notes[i].folder === note.folder) { next = index.notes[i].order; break; }
        return place(index, note, previous, next);
      });
      if (changed) {
        const seen = new Set();
        for (const note of changed) {
          if (seen.has(note.id)) continue;
          seen.add(note.id);
          onWorkspace({ type: "noteMove", ...note });
        }
      }
    },

    createFolder(name) {
      const folder = change((index) => {
        const last = index.folders[index.folders.length - 1];
        const created = { id: newId(), name: name.trim() || "新資料夾", open: true, order: orderBetween(last?.order, null) };
        index.folders.push(created);
        return created;
      });
      onWorkspace({ type: "folder", id: folder.id, name: folder.name, order: folder.order });
      return folder.id;
    },

    renameFolder(id, name) {
      const renamed = change((index) => {
        const folder = index.folders.find((f) => f.id === id);
        if (!folder || !name.trim()) return null;
        folder.name = name.trim();
        return folder.name;
      });
      if (renamed) onWorkspace({ type: "folderRename", id, name: renamed });
    },

    toggleFolder(id, open) {
      change((index) => {
        const folder = index.folders.find((f) => f.id === id);
        if (folder) folder.open = open ?? !folder.open;
      }, false);
    },

    /** Removes a folder; its notes move to the top level, nothing is lost. */
    deleteFolder(id) {
      const removed = change((index) => {
        const before = index.folders.length;
        index.folders = index.folders.filter((f) => f.id !== id);
        if (index.folders.length === before) return false;
        const moved = [];
        for (const note of index.notes) {
          if (note.folder !== id) continue;
          note.folder = null;
          moved.push({ id: note.id, order: note.order });
        }
        return moved;
      });
      if (removed) {
        onWorkspace({ type: "folderDelete", id });
        for (const note of removed) onWorkspace({ type: "noteMove", ...note, folder: null });
      }
    },

    /** Adds whichever of the four PARA folders are missing; returns how many were added. */
    addPara() {
      const added = change((index) => {
        const have = new Set(index.folders.map((f) => f.name.toLowerCase()));
        const missing = PARA.filter((name) => !have.has(name.toLowerCase()));
        const out = [];
        for (const name of missing) {
          const last = index.folders[index.folders.length - 1];
          const folder = { id: newId(), name, open: true, order: orderBetween(last?.order, null) };
          index.folders.push(folder);
          out.push(folder);
        }
        return out;
      });
      for (const folder of added) onWorkspace({ type: "folder", id: folder.id, name: folder.name, order: folder.order });
      return added.length;
    },

    // ------------------------------------------------ for cloud sync (sync.js)

    newId,

    /** Every folder ({id, name}) and note ({id, folder, updated, body}), in sidebar order. */
    snapshot() {
      const index = load();
      return {
        folders: index.folders.map(({ id, name }) => ({ id, name })),
        notes: index.notes.map(({ id, folder, updated }) => ({ id, folder, updated, body: get(BODY_KEY(id)) || "" })),
      };
    },

    /** The organization only (folders and note placement/order), for workspace.js. */
    workspaceState() {
      const index = load();
      return {
        folders: index.folders.map(({ id, name, order }) => ({ id, name, order })),
        notes: index.notes.map(({ id, folder, order }) => ({ id, folder, order })),
      };
    },

    /**
     * Writes a note that came from elsewhere: replaces its body and folder,
     * or adds it at the top of its folder. Keeps `updated` and never changes
     * which note is open. An unknown folder means the top level.
     */
    put({ id, folder, updated, body, order }) {
      set(BODY_KEY(id), body);
      change((index) => {
        const known = index.folders.some((f) => f.id === folder) ? folder : null;
        let note = index.notes.find((n) => n.id === id);
        if (!note) {
          const first = index.notes.find((n) => n.folder === known);
          note = { id, folder: known, order: order || orderBetween(null, first?.order) };
          const to = index.notes.findIndex((n) => n.folder === known);
          index.notes.splice(to < 0 ? index.notes.length : to, 0, note);
        }
        note.folder = known;
        if (order) note.order = order;
        note.title = titleOf(body);
        note.updated = updated || Date.now();
      });
    },

    /**
     * Applies the merged workspace view (folders and note placement/order)
     * without touching bodies or which note is open. Local-only folder open
     * state is kept; notes of a folder that is gone move to the top level.
     */
    applyWorkspace({ folders, notes }) {
      const index = load();
      const signature = () => JSON.stringify([
        index.folders.map((f) => [f.id, f.name, f.order]),
        index.notes.map((n) => [n.id, n.folder, n.order]),
      ]);
      const before = signature();
      const open = new Map(index.folders.map((f) => [f.id, f.open]));
      const folderIds = new Set(folders.map((f) => f.id));
      index.folders = folders.map(({ id, name, order }) => ({
        id, name, order, open: open.get(id) ?? true,
      }));
      const meta = new Map(notes.map((n) => [n.id, n]));
      for (const note of index.notes) {
        const merged = meta.get(note.id);
        if (merged) {
          note.folder = folderIds.has(merged.folder) ? merged.folder : null;
          if (merged.order) note.order = merged.order;
        } else if (note.folder && !folderIds.has(note.folder)) {
          note.folder = null;
        }
      }
      index.notes.sort(byOrder);
      if (signature() === before) return false;
      set(INDEX_KEY, JSON.stringify(index));
      onChange();
      return true;
    },

    /** Replaces the folder list ({id, name}); open state is kept, notes of a removed folder move to the top level. */
    setFolders(list) {
      change((index) => {
        const open = new Map(index.folders.map((f) => [f.id, f.open]));
        const order = new Map(index.folders.map((f) => [f.id, f.order]));
        index.folders = list.map(({ id, name, order: given }) => ({
          id, name, order: order.get(id) || given || null, open: open.get(id) ?? true,
        }));
        ensureOrders(index);
        const ids = new Set(list.map((f) => f.id));
        for (const note of index.notes) if (note.folder && !ids.has(note.folder)) note.folder = null;
      });
    },

    /** The storage key of the index, to notice another tab's changes. */
    indexKey: INDEX_KEY,
  };
}
