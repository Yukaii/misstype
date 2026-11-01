// Workspace state for the editor: which folders exist, what they are called,
// which note sits in which folder and in what order. The note bodies stay in
// notes.js / the Markdown files; this is only the organization around them.
//
// A Y.Doc per browser keeps this state, so two devices that saw different
// versions of the same folder/note merge without a server: the folders and
// note placements are maps of independent fields, not a whole JSON blob with
// a winner. Each device writes only its own remote file:
//
//   workspace.<device>.json   { v: 1, device, state: base64(Y.Doc update) }
//
// A pass reads every workspace.*.json, applies it (idempotent), then writes
// its own file if the others do not already have its changes. Because no two
// devices write the same file, Google Drive's lack of a conditional write
// cannot lose an update. The files are small: names, folder ids, order keys.
//
// Merge policy: folder renames and moves are last-writer-wins per field. A
// folder delete is a tombstone; a later rename can bring it back. A note is
// never deleted here: its body file (sync.js) decides whether it exists, so
// the existing edit-beats-delete rule stays. A note whose folder is gone is
// shown at the top level, not deleted.
import * as Y from "yjs";

const DOC_KEY = "misstype-editor-workspace";
const DEVICE_KEY = "misstype-editor-device";
const FILE = /^workspace\.([A-Za-z0-9_-]+)\.json$/;

export const isWorkspaceFile = (name) => FILE.test(name);
export const workspaceFile = (device) => `workspace.${device}.json`;

// Fractional-index keys are ASCII; localeCompare would put "a0" before "Zz"
// (case-insensitive), which is the opposite of their intended order.
const byOrder = (a, b) => {
  const ao = a.order || "";
  const bo = b.order || "";
  if (ao !== bo) return ao < bo ? -1 : 1;
  return a.id < b.id ? -1 : a.id > b.id ? 1 : 0;
};

const bytesToB64 = (bytes) => {
  let text = "";
  for (let i = 0; i < bytes.length; i += 0x8000) {
    text += String.fromCharCode(...bytes.subarray(i, i + 0x8000));
  }
  return btoa(text);
};
const b64ToBytes = (text) => {
  const bin = atob(text);
  const bytes = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
  return bytes;
};

const read = (storage, key) => {
  try { return storage.getItem(key); } catch { return null; }
};
const write = (storage, key, value) => {
  try { storage.setItem(key, value); } catch { /* storage full or private mode */ }
};

const deviceOf = (storage) => {
  let id = read(storage, DEVICE_KEY);
  if (!id) {
    const bytes = crypto.getRandomValues(new Uint8Array(9));
    id = [...bytes].map((b) => b.toString(36).padStart(2, "0")).join("").slice(0, 12);
    write(storage, DEVICE_KEY, id);
  }
  return id;
};

const field = (entry, key, fallback = null) => {
  const value = entry?.get?.(key);
  return value === undefined ? fallback : value;
};

/**
 * `storage` is localStorage-like (the tests pass a Map wrapper). `onChange`
 * fires when a local or remote merge changed this device's view.
 */
export function createWorkspace({ storage = globalThis.localStorage, onChange = () => {} } = {}) {
  const doc = new Y.Doc();
  const folders = doc.getMap("folders");
  const notes = doc.getMap("notes");
  const device = deviceOf(storage);
  let loaded = false;

  function load() {
    if (loaded) return;
    loaded = true;
    const state = read(storage, DOC_KEY);
    if (!state) return;
    try { Y.applyUpdate(doc, b64ToBytes(state)); } catch { /* damaged state: start empty */ }
  }

  /** Merges another tab's saved state into this in-memory doc. */
  function reload() {
    load();
    const state = read(storage, DOC_KEY);
    if (!state) return false;
    const before = Y.encodeStateVector(doc);
    try { Y.applyUpdate(doc, b64ToBytes(state)); } catch { return false; }
    return !sameVector(before, Y.encodeStateVector(doc));
  }

  function persist() {
    write(storage, DOC_KEY, bytesToB64(Y.encodeStateAsUpdate(doc)));
  }

  function sameVector(a, b) {
    if (a.length !== b.length) return false;
    for (let i = 0; i < a.length; i++) if (a[i] !== b[i]) return false;
    return true;
  }

  function noteEntry(id, create = false) {
    let entry = notes.get(id);
    if (!(entry instanceof Y.Map)) {
      if (!create) return null;
      entry = new Y.Map();
      notes.set(id, entry);
    }
    return entry;
  }

  function folderEntry(id, create = false) {
    let entry = folders.get(id);
    if (!(entry instanceof Y.Map)) {
      if (!create) return null;
      entry = new Y.Map();
      folders.set(id, entry);
    }
    return entry;
  }

  /** Adds only metadata that is missing; it never overwrites merged remote values. */
  function ensure({ folders: localFolders = [], notes: localNotes = [] } = {}) {
    reload();
    let changed = false;
    for (const folder of localFolders) {
      if (!folder?.id) continue;
      const entry = folders.get(folder.id);
      if (!(entry instanceof Y.Map)) {
        const created = folderEntry(folder.id, true);
        created.set("name", folder.name || "新資料夾");
        created.set("order", folder.order || null);
        created.set("deleted", false);
        changed = true;
      } else {
        if (field(entry, "name") === undefined) { entry.set("name", folder.name || "新資料夾"); changed = true; }
        if (field(entry, "order") == null && folder.order) { entry.set("order", folder.order); changed = true; }
        if (field(entry, "deleted") === undefined) { entry.set("deleted", false); changed = true; }
      }
    }
    for (const note of localNotes) {
      if (!note?.id) continue;
      const entry = notes.get(note.id);
      if (!(entry instanceof Y.Map)) {
        const created = noteEntry(note.id, true);
        created.set("folder", note.folder ?? null);
        created.set("order", note.order || null);
        changed = true;
      } else {
        if (field(entry, "folder") === undefined) { entry.set("folder", note.folder ?? null); changed = true; }
        if (field(entry, "order") == null && note.order) { entry.set("order", note.order); changed = true; }
      }
    }
    if (changed) { persist(); onChange(); }
    return changed;
  }

  /** Applies one local edit from notes.js. */
  function applyLocal(op) {
    if (!op?.type) return;
    reload();
    let changed = false;
    if (op.type === "note" || op.type === "noteMove") {
      const entry = noteEntry(op.id, true);
      if (field(entry, "folder") !== (op.folder ?? null)) { entry.set("folder", op.folder ?? null); changed = true; }
      if (op.order && field(entry, "order") !== op.order) { entry.set("order", op.order); changed = true; }
    } else if (op.type === "noteDelete") {
      if (notes.has(op.id)) { notes.delete(op.id); changed = true; }
    } else if (op.type === "folder") {
      const entry = folderEntry(op.id, true);
      if (field(entry, "name") !== (op.name || "")) { entry.set("name", op.name || ""); changed = true; }
      if (op.order && field(entry, "order") !== op.order) { entry.set("order", op.order); changed = true; }
      if (field(entry, "deleted")) { entry.set("deleted", false); changed = true; } // a reused id is not a tombstone
    } else if (op.type === "folderRename") {
      const entry = folderEntry(op.id, true);
      if (field(entry, "name") !== (op.name || "") || field(entry, "deleted")) {
        entry.set("name", op.name || "");
        entry.set("deleted", false); // a later rename brings the folder back
        changed = true;
      }
    } else if (op.type === "folderDelete") {
      const entry = folderEntry(op.id, false);
      if (entry && !field(entry, "deleted")) {
        entry.set("deleted", true);
        changed = true;
      }
    }
    if (changed) { persist(); onChange(); }
    return changed;
  }

  /** The merged view, sorted for the sidebar. */
  function projection() {
    const folderList = [];
    for (const [id, entry] of folders) {
      if (!(entry instanceof Y.Map) || field(entry, "deleted") === true) continue;
      folderList.push({ id, name: field(entry, "name", ""), order: field(entry, "order") });
    }
    folderList.sort(byOrder);
    const noteList = [];
    for (const [id, entry] of notes) {
      if (!(entry instanceof Y.Map)) continue;
      noteList.push({ id, folder: field(entry, "folder"), order: field(entry, "order") });
    }
    noteList.sort(byOrder);
    return { folders: folderList, notes: noteList };
  }

  function meta(id) {
    load();
    const entry = notes.get(id);
    if (!(entry instanceof Y.Map)) return null;
    return { id, folder: field(entry, "folder"), order: field(entry, "order") };
  }

  /** Applies the merged CRDT state to the local notes index. */
  function project(store) {
    reload();
    const view = projection();
    return store.applyWorkspace(view);
  }

  /**
   * Reads and merges every remote workspace file. Returns the state vector
   * those files cover, for upload(). Corrupt or foreign files are ignored.
   */
  async function applyRemote(files, readFile) {
    reload();
    const before = Y.encodeStateVector(doc);
    let merged = null;
    for (const [name] of files) {
      let parsed;
      try { parsed = JSON.parse(await readFile(name) || ""); } catch { continue; }
      if (parsed?.v !== 1 || typeof parsed.state !== "string") continue;
      try {
        const update = b64ToBytes(parsed.state);
        Y.applyUpdate(doc, update);
        merged = merged ? Y.mergeUpdates([merged, update]) : update;
      } catch { /* damaged file: the other devices still have it */ }
    }
    const changed = !sameVector(before, Y.encodeStateVector(doc));
    if (changed) persist();
    return {
      changed,
      vector: merged ? Y.encodeStateVectorFromUpdate(merged) : new Uint8Array([0, 0]),
    };
  }

  /**
   * Writes this device's file when the remote files do not already cover its
   * state. `files` is the sync pass's list map (name -> {rev}), so a lost
   * conditional write is retried on the next pass instead of being forced.
   */
  async function upload({ files, vector, write: writeFile }) {
    const name = workspaceFile(device);
    const existing = files.get(name);
    const delta = Y.encodeStateAsUpdate(doc, vector?.length ? vector : undefined);
    // [0, 0] is an empty update; "no own file" still needs a first upload.
    if (delta.length <= 2 && existing) return null;
    if (delta.length <= 2 && !existing && folders.size === 0 && notes.size === 0) return null;
    const text = JSON.stringify({ v: 1, device, state: bytesToB64(Y.encodeStateAsUpdate(doc)) });
    try {
      return { name, rev: await writeFile(name, text, existing?.rev ?? null) };
    } catch (err) {
      if (err?.conflict) return null;
      throw err;
    }
  }

  load();
  return {
    device,
    storageKey: DOC_KEY,
    ensure,
    applyLocal,
    projection,
    meta,
    project,
    applyRemote,
    upload,
    reload,
    /** For tests: the raw merged state. */
    state: () => bytesToB64(Y.encodeStateAsUpdate(doc)),
  };
}
