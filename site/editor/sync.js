// Cloud sync of the editor's notes, independent of the provider (cloud.js
// has Dropbox and Google Drive). The remote side is a folder of plain files:
//
//   notes/<id>.md   one note: a short front matter (folder, updated), then the Markdown
//   folders.json    {"v": 1, "folders": [{"id", "name"}]}
//
// Sync is three-way: `base` remembers, per note, the remote revision and a
// hash of the content both sides agreed on last time, so a pass can tell
// "changed here", "changed there" and "deleted" apart without timestamps.
// One-sided changes and deletions go across; an edit beats a delete; when both
// sides edited a note, the local text keeps the note and the remote text
// becomes a new note next to it. Nothing typed is ever dropped.
//
// A remote is { list(), read(name), write(name, text, rev), remove(name) }:
// list() gives [{name, rev}], write returns the new rev and throws an error
// with `conflict: true` when `rev` (null: the file must not exist yet) no
// longer matches; that note is left for the next pass.
//
// Once workspace.js has state in the remote (workspace.<device>.json), the
// folder list and each note's folder/order come from that CRDT instead of
// folders.json / the note front matter. Bodies keep the three-way merge above;
// folders.json is only read while no workspace state exists (migration).

import { isWorkspaceFile } from "./workspace.js";

export const FOLDERS_FILE = "folders.json";
const NOTE_FILE = /^notes\/([^/]+)\.md$/i;
export const noteFile = (id) => `notes/${id}.md`;

/** A short string hash (cyrb53), enough to notice that content changed. */
export function hashOf(text) {
  let h1 = 0xdeadbeef;
  let h2 = 0x41c6ce57;
  for (let i = 0; i < text.length; i++) {
    const c = text.charCodeAt(i);
    h1 = Math.imul(h1 ^ c, 2654435761);
    h2 = Math.imul(h2 ^ c, 1597334677);
  }
  h1 = Math.imul(h1 ^ (h1 >>> 16), 2246822507) ^ Math.imul(h2 ^ (h2 >>> 13), 3266489909);
  h2 = Math.imul(h2 ^ (h2 >>> 16), 2246822507) ^ Math.imul(h1 ^ (h1 >>> 13), 3266489909);
  return (4294967296 * (2097151 & h2) + (h1 >>> 0)).toString(36);
}

// The body only: a folder move or reorder belongs to workspace.js, so it must
// not look like a body edit and make a concurrent edit elsewhere a conflict.
const noteHash = ({ body }) => hashOf(body);
// Hashes written by versions before the workspace CRDT include the folder.
const legacyNoteHash = ({ folder, body }) => hashOf(`${folder ?? ""}\n${body}`);
const hashMatches = (was, note) => Boolean(was) && (noteHash(note) === was.hash || legacyNoteHash(note) === was.hash);

export function formatNote({ folder, updated, body }) {
  return `---\nmisstype: 1\nfolder: ${folder ?? ""}\nupdated: ${new Date(updated || 0).toISOString()}\n---\n${body}`;
}

/** Reads a note file; a Markdown file without our front matter is a note at the top level. */
export function parseNote(text) {
  const head = /^---\r?\n((?:.*\r?\n)*?)---\r?\n/.exec(text);
  if (!head || !/^misstype:/m.test(head[1])) return { folder: null, updated: 0, body: text };
  const field = (key) => new RegExp(`^${key}:[ \\t]*(.*?)[ \\t]*\\r?$`, "m").exec(head[1])?.[1] ?? "";
  return { folder: field("folder") || null, updated: Date.parse(field("updated")) || 0, body: text.slice(head[0].length) };
}

/**
 * Three-way merge of folder lists ({id, name}). A folder added on either side
 * stays, one deleted on a side where the other did not rename it goes, and
 * when both renamed it the local name wins. Local order first.
 */
export function mergeFolders(base, local, remote) {
  const b = new Map(base.map((f) => [f.id, f]));
  const r = new Map(remote.map((f) => [f.id, f]));
  const l = new Map(local.map((f) => [f.id, f]));
  const out = [];
  for (const id of new Set([...l.keys(), ...r.keys()])) {
    const was = b.get(id);
    const mine = l.get(id);
    const theirs = r.get(id);
    if (mine && theirs) {
      out.push({ id, name: was && mine.name === was.name ? theirs.name : mine.name });
    } else if (mine) {
      if (!was || mine.name !== was.name) out.push({ id, name: mine.name });
    } else if (!was || theirs.name !== was.name) {
      out.push({ id, name: theirs.name });
    }
  }
  return out;
}

const sameFolders = (a, b) => a.length === b.length && a.every((f, i) => f.id === b[i].id && f.name === b[i].name);

/**
 * One sync pass. `store` is the notes store (notes.js), `base` the state the
 * previous pass returned ({} the first time). `busy(id)` says a note has
 * unsaved edits on screen, so remote text must not replace it this pass.
 * Returns the new base and what happened.
 */
export async function syncNotes({ store, remote, base = {}, busy = () => false, workspace = null }) {
  const report = { uploaded: 0, downloaded: 0, deleted: 0, conflicts: 0, changed: new Set() };
  const files = new Map((await remote.list()).map((f) => [f.name, f]));
  const workspaceFiles = new Map([...files].filter(([name]) => isWorkspaceFile(name)));
  // Once any device has written its workspace state, the CRDT owns folders and
  // note placement. Until then this pass is the one-time migration from
  // folders.json / the note front matter.
  const wsActive = Boolean(workspace) && workspaceFiles.size > 0;
  let wsVector = null;
  if (wsActive) {
    wsVector = (await workspace.applyRemote(workspaceFiles, (name) => remote.read(name))).vector;
    // Keep organization this device made while it had no workspace state (a
    // cleared profile, or an index from before the upgrade) before projecting
    // the remote view over it; ensure() only adds what the CRDT is missing.
    workspace.ensure(store.workspaceState());
    workspace.project(store);
  }
  // folders.json is always written, so its absence after an earlier pass means
  // the remote folder was wiped (or is another one): a fresh start, not a
  // request to delete every note here. Workspace state replaces that signal.
  if (!wsActive && base.folders && !files.has(FOLDERS_FILE)) base = {};
  const next = { folders: base.folders, notes: {} };

  // Folders first, so remote notes find their folder. With workspace state the
  // merge above already projected the folder list, and folders.json is legacy.
  if (!wsActive) {
    const folderFile = files.get(FOLDERS_FILE);
    const baseFolders = base.folders?.list ?? [];
    let remoteFolders = [];
    if (folderFile) {
      remoteFolders = folderFile.rev === base.folders?.rev
        ? baseFolders
        : (JSON.parse(await remote.read(FOLDERS_FILE) || "{}").folders ?? []).filter((f) => f?.id && typeof f.name === "string");
    }
    const localFolders = store.snapshot().folders;
    const folders = mergeFolders(baseFolders, localFolders, remoteFolders);
    if (!sameFolders(folders, localFolders)) store.setFolders(folders);
    if (!folderFile || !sameFolders(folders, remoteFolders)) {
      try {
        const rev = await remote.write(FOLDERS_FILE, `${JSON.stringify({ v: 1, folders }, null, 2)}\n`, folderFile?.rev ?? null);
        next.folders = { rev, list: folders };
      } catch (err) {
        if (!err.conflict) throw err;
      }
    } else if (folderFile) {
      next.folders = { rev: folderFile.rev, list: folders };
    }
  }

  const local = new Map(store.snapshot().notes.map((n) => [n.id, n]));
  const remoteNotes = new Map();
  for (const file of files.values()) {
    const m = NOTE_FILE.exec(file.name);
    if (m) remoteNotes.set(m[1], file);
  }
  // The note as stored right now, to skip one the user changed while this pass waited on the network.
  const untouched = (id, seen) => {
    if (busy(id)) return false;
    const now = store.snapshot().notes.find((n) => n.id === id);
    return seen ? Boolean(now) && noteHash(now) === noteHash(seen) : !now;
  };
  const upload = async (note, rev) => {
    const text = formatNote(note);
    next.notes[note.id] = { rev: await remote.write(noteFile(note.id), text, rev), hash: noteHash(note) };
    report.uploaded++;
  };
  const download = async (id, file) => {
    const parsed = parseNote(await remote.read(file.name));
    const meta = workspace && wsActive ? workspace.meta(id) : null;
    return {
      id,
      ...parsed,
      // Workspace placement wins; the front matter is the migration/backup hint.
      folder: meta ? meta.folder : parsed.folder,
      order: meta?.order,
    };
  };
  const adopt = (note, rev) => {
    store.put(note);
    const stored = store.snapshot().notes.find((n) => n.id === note.id);
    next.notes[note.id] = { rev, hash: noteHash(stored) };
    report.downloaded++;
    report.changed.add(note.id);
  };

  for (const id of new Set([...local.keys(), ...remoteNotes.keys(), ...Object.keys(base.notes ?? {})])) {
    const was = base.notes?.[id];
    const mine = local.get(id);
    const file = remoteNotes.get(id);
    if (!mine && !file) continue;
    // Accept the pre-workspace (folder + body) hash too, so the upgrade does not
    // turn every unchanged note into a local edit.
    const mineChanged = mine ? (!was || !hashMatches(was, mine)) : Boolean(was);
    const theirsChanged = file ? !was || file.rev !== was.rev : Boolean(was);
    try {
      if (!mineChanged && !theirsChanged) {
        next.notes[id] = was;
      } else if (!theirsChanged) {
        if (mine) {
          // A fresh empty note (every device starts with one) is not worth a file.
          if (was || mine.body.trim()) await upload(mine, file?.rev ?? null);
        } else {
          await remote.remove(file.name);
          report.deleted++;
        }
      } else if (!mineChanged) {
        if (file) {
          const theirs = await download(id, file);
          if (untouched(id, mine)) adopt(theirs, file.rev);
          else if (was) next.notes[id] = was;
        } else if (untouched(id, mine)) {
          store.delete(id);
          report.deleted++;
          report.changed.add(id);
        } else if (was) next.notes[id] = was;
      } else if (!file) {
        // Edited here, deleted there: the edit wins.
        await upload(mine, null);
      } else {
        const theirs = await download(id, file);
        if (!mine) {
          // Deleted here, edited there: the edit wins.
          adopt(theirs, file.rev);
        } else if (noteHash(theirs) === noteHash(mine)) {
          next.notes[id] = { rev: file.rev, hash: noteHash(mine) };
        } else {
          // Both edited: keep both. The remote text becomes a note of its own.
          const copy = { ...theirs, id: store.newId() };
          adopt(copy, null);
          await upload(copy, null);
          await upload(mine, file.rev);
          report.conflicts++;
        }
      }
    } catch (err) {
      if (!err.conflict) throw err;
      // Someone wrote the file in the meantime: keep the old base, next pass sees both sides.
      if (was) next.notes[id] = was;
    }
  }
  if (workspace) {
    // Seed any note/folder this device has but the CRDT has not seen yet (first
    // migration pass, or a note that came in with a body only), then push the
    // merged organization to its own static file.
    workspace.ensure(store.workspaceState());
    workspace.project(store);
    await workspace.upload({
      files,
      vector: wsVector,
      write: (name, text, rev) => remote.write(name, text, rev),
    });
  }
  report.changed = [...report.changed];
  return { base: next, report };
}
