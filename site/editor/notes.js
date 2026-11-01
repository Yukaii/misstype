// The editor's notes: an index (folders, note order, titles, which note is
// open) plus one localStorage key per note body, so typing rewrites only the
// note being edited. Folders are one level deep (enough for PARA: Projects,
// Areas, Resources, Archives); a note sits in a folder or at the top level.
//
// Every change reads the index afresh, edits it and writes it back, so a
// second tab (or the installed app next to a Safari tab) does not wipe out
// notes the other one created.

const INDEX_KEY = "misstype-editor-notes";
const BODY_KEY = (id) => `misstype-editor-note:${id}`;
/** The single note of earlier versions; becomes the first note. */
const LEGACY_KEY = "misstype-editor-md";

export const PARA = ["Projects", "Areas", "Resources", "Archives"];
export const UNTITLED = "未命名";

const newId = () => Date.now().toString(36) + Math.random().toString(36).slice(2, 7);

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

/** `onChange` hears every change to what is stored (not which note is open or which folders are expanded). */
export function createNotes(storage = globalThis.localStorage, { onChange = () => {} } = {}) {
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
      return index;
    }
    // First visit, or an earlier version's single note.
    const legacy = get(LEGACY_KEY) || "";
    const note = { ...blankNote(null), title: titleOf(legacy) };
    index = { v: 1, current: note.id, folders: [], notes: [note] };
    if (legacy) set(BODY_KEY(note.id), legacy);
    if (set(INDEX_KEY, JSON.stringify(index)) && legacy) remove(LEGACY_KEY);
    return index;
  }

  const blankNote = (folder) => ({ id: newId(), folder, title: "", updated: Date.now() });

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
      return change((index) => {
        const note = { ...blankNote(index.folders.some((f) => f.id === folder) ? folder : null), title: titleOf(markdown) };
        if (markdown) set(BODY_KEY(note.id), markdown);
        index.notes.unshift(note);
        index.current = note.id;
        const parent = index.folders.find((f) => f.id === note.folder);
        if (parent) parent.open = true;
        return note.id;
      });
    },

    /** Deletes a note; returns the id that is open afterwards. */
    delete(id) {
      remove(BODY_KEY(id));
      return change((index) => {
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
            index.notes.push(note);
            index.current = note.id;
          }
        }
        return index.current;
      });
    },

    /** Moves a note into `folder` (null: top level), before note `before` or at the folder's top. */
    move(id, folder, before = null) {
      change((index) => {
        const at = index.notes.findIndex((n) => n.id === id);
        if (at < 0 || id === before) return;
        const [note] = index.notes.splice(at, 1);
        note.folder = index.folders.some((f) => f.id === folder) ? folder : null;
        let to = before ? index.notes.findIndex((n) => n.id === before) : -1;
        if (to < 0) to = index.notes.findIndex((n) => n.folder === note.folder);
        index.notes.splice(to < 0 ? index.notes.length : to, 0, note);
      });
    },

    createFolder(name) {
      return change((index) => {
        const folder = { id: newId(), name: name.trim() || "新資料夾", open: true };
        index.folders.push(folder);
        return folder.id;
      });
    },

    renameFolder(id, name) {
      change((index) => {
        const folder = index.folders.find((f) => f.id === id);
        if (folder && name.trim()) folder.name = name.trim();
      });
    },

    toggleFolder(id, open) {
      change((index) => {
        const folder = index.folders.find((f) => f.id === id);
        if (folder) folder.open = open ?? !folder.open;
      }, false);
    },

    /** Removes a folder; its notes move to the top level, nothing is lost. */
    deleteFolder(id) {
      change((index) => {
        index.folders = index.folders.filter((f) => f.id !== id);
        for (const note of index.notes) if (note.folder === id) note.folder = null;
      });
    },

    /** Adds whichever of the four PARA folders are missing; returns how many were added. */
    addPara() {
      return change((index) => {
        const have = new Set(index.folders.map((f) => f.name.toLowerCase()));
        const missing = PARA.filter((name) => !have.has(name.toLowerCase()));
        for (const name of missing) index.folders.push({ id: newId(), name, open: true });
        return missing.length;
      });
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

    /**
     * Writes a note that came from elsewhere: replaces its body and folder,
     * or adds it at the top of its folder. Keeps `updated` and never changes
     * which note is open. An unknown folder means the top level.
     */
    put({ id, folder, updated, body }) {
      set(BODY_KEY(id), body);
      change((index) => {
        const known = index.folders.some((f) => f.id === folder) ? folder : null;
        let note = index.notes.find((n) => n.id === id);
        if (!note) {
          note = { id, folder: known };
          const to = index.notes.findIndex((n) => n.folder === known);
          index.notes.splice(to < 0 ? index.notes.length : to, 0, note);
        }
        note.folder = known;
        note.title = titleOf(body);
        note.updated = updated || Date.now();
      });
    },

    /** Replaces the folder list ({id, name}); open state is kept, notes of a removed folder move to the top level. */
    setFolders(list) {
      change((index) => {
        const open = new Map(index.folders.map((f) => [f.id, f.open]));
        index.folders = list.map(({ id, name }) => ({ id, name, open: open.get(id) ?? true }));
        const ids = new Set(list.map((f) => f.id));
        for (const note of index.notes) if (note.folder && !ids.has(note.folder)) note.folder = null;
      });
    },

    /** The storage key of the index, to notice another tab's changes. */
    indexKey: INDEX_KEY,
  };
}
