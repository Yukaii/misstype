// Checks the editor's workspace CRDT (site/editor/workspace.js) together with
// the body merge (sync.js): folders and note placement/order go through
// per-device static Yjs files, bodies stay in notes/<id>.md, and two devices
// converge without a server or a conflict copy when one moves a note while the
// other edits its text.
//   cd site && npm ci && node ../tests/editor_workspace_test.mjs
import assert from "node:assert/strict";
import test from "node:test";
import { createNotes } from "../site/editor/notes.js";
import { createWorkspace, isWorkspaceFile } from "../site/editor/workspace.js";
import { hashOf, syncNotes } from "../site/editor/sync.js";

const memory = () => {
  const map = new Map();
  return {
    getItem: (k) => (map.has(k) ? map.get(k) : null),
    setItem: (k, v) => map.set(k, String(v)),
    removeItem: (k) => map.delete(k),
  };
};

function memoryRemote() {
  const files = new Map();
  const writes = [];
  let counter = 0;
  return {
    files,
    writes,
    list: async () => [...files].map(([name, f]) => ({ name, rev: f.rev })),
    read: async (name) => files.get(name)?.text ?? "",
    async write(name, text, rev) {
      const have = files.get(name);
      if ((have?.rev ?? null) !== rev) throw Object.assign(new Error("conflict"), { conflict: true });
      files.set(name, { text, rev: `r${++counter}` });
      writes.push(name);
      return `r${counter}`;
    },
    remove: async (name) => { files.delete(name); },
  };
}

/** A device; `crdt` adds the workspace file and notes.js -> workspace wiring. */
function device(remote, { crdt = false } = {}) {
  let ws = null;
  const store = createNotes(memory(), crdt ? { onWorkspace: (op) => ws?.applyLocal(op) } : {});
  if (crdt) {
    ws = createWorkspace({ storage: memory() });
    ws.ensure(store.workspaceState());
  }
  let base = {};
  return {
    store,
    get ws() { return ws; },
    get base() { return base; },
    set base(value) { base = value; },
    async sync(busy) {
      const out = await syncNotes({ store, remote, base, busy, workspace: ws });
      base = out.base;
      return out.report;
    },
    note: (id) => store.load().notes.find((n) => n.id === id),
    folder: (name) => store.load().folders.find((f) => f.name === name),
    folders: () => store.load().folders,
  };
}

test("folders and placements travel in a per-device static workspace file", async () => {
  const remote = memoryRemote();
  const a = device(remote, { crdt: true });
  const b = device(remote, { crdt: true });
  const work = a.store.createFolder("Work");
  const id = a.store.create(work, "會議紀錄");

  await a.sync();
  await b.sync();

  assert.equal(b.folder("Work")?.id, work);
  assert.equal(b.note(id)?.folder, work);
  assert.deepEqual(b.store.snapshot().folders.map((f) => f.name), ["Work"]);
  const files = [...remote.files.keys()].filter(isWorkspaceFile);
  assert.equal(files.length, 2, "one file per device, never a shared one");
  assert.ok(files.every((name) => remote.files.has(name)));
  assert.ok(remote.files.has(`notes/${id}.md`));
});

test("a move and a body edit on different devices do not become a conflict", async () => {
  const remote = memoryRemote();
  const a = device(remote, { crdt: true });
  const b = device(remote, { crdt: true });
  const work = a.store.createFolder("Work");
  const id = a.store.create(null, "原文");

  await a.sync();
  await b.sync();

  a.store.move(id, work);
  b.store.write(id, "B 改過的文字");
  await a.sync();
  const report = await b.sync();
  await a.sync();

  assert.equal(report.conflicts, 0);
  assert.equal(a.store.read(id), "B 改過的文字");
  assert.equal(b.store.read(id), "B 改過的文字");
  assert.equal(a.note(id)?.folder, work);
  assert.equal(b.note(id)?.folder, work);
  assert.equal(a.store.load().notes.filter((n) => n.id === id).length, 1);
  assert.equal(b.store.load().notes.filter((n) => n.id === id).length, 1);
});

test("concurrent folder renames and note moves converge on both devices", async () => {
  const remote = memoryRemote();
  const a = device(remote, { crdt: true });
  const b = device(remote, { crdt: true });
  const work = a.store.createFolder("Work");
  const home = a.store.createFolder("Home");
  const id = a.store.create(work, "筆記");

  await a.sync();
  await b.sync();

  a.store.renameFolder(work, "工作");
  b.store.renameFolder(work, "Office");
  a.store.move(id, home);
  b.store.move(id, work);
  await a.sync();
  await b.sync();
  await a.sync();
  await b.sync();

  assert.deepEqual(a.folders().map((f) => f.id), b.folders().map((f) => f.id));
  assert.deepEqual(a.folders().map((f) => f.name), b.folders().map((f) => f.name));
  assert.equal(a.note(id)?.folder, b.note(id)?.folder);
  assert.equal(a.store.load().notes.filter((n) => n.id === id).length, 1);
  assert.equal(b.store.load().notes.filter((n) => n.id === id).length, 1);
});

test("a deleted folder takes its notes to the top, even with a concurrent move", async () => {
  const remote = memoryRemote();
  const a = device(remote, { crdt: true });
  const b = device(remote, { crdt: true });
  const work = a.store.createFolder("Work");
  const id = a.store.create(null, "留著");

  await a.sync();
  await b.sync();

  a.store.deleteFolder(work);
  b.store.move(id, work);
  await a.sync();
  await b.sync();
  await a.sync();
  await b.sync();

  assert.ok(!a.folders().some((f) => f.id === work));
  assert.ok(!b.folders().some((f) => f.id === work));
  assert.equal(a.note(id)?.folder, null);
  assert.equal(b.note(id)?.folder, null);
  assert.equal(a.store.read(id), "留著");
  assert.equal(b.store.load().notes.filter((n) => n.id === id).length, 1);
});

test("note order inside a folder follows a move across devices", async () => {
  const remote = memoryRemote();
  const a = device(remote, { crdt: true });
  const b = device(remote, { crdt: true });
  const work = a.store.createFolder("Work");
  const first = a.store.create(work, "一");
  const second = a.store.create(work, "二");

  await a.sync();
  await b.sync();
  assert.deepEqual(b.store.load().notes.filter((n) => n.folder === work).map((n) => n.id), [second, first]);

  // Move the first note above the second one: before the only note in the folder.
  a.store.move(first, work, second);
  await a.sync();
  await b.sync();

  assert.deepEqual(a.store.load().notes.filter((n) => n.folder === work).map((n) => n.id), [first, second]);
  assert.deepEqual(b.store.load().notes.filter((n) => n.folder === work).map((n) => n.id), [first, second]);
});

test("concurrent top-of-folder notes with the same key can still be reordered", async () => {
  const remote = memoryRemote();
  const a = device(remote, { crdt: true });
  const b = device(remote, { crdt: true });
  const work = a.store.createFolder("Work");
  const old = a.store.create(work, "舊");
  await a.sync();
  await b.sync();

  // Both devices insert at the top of the same folder before seeing each other:
  // both generate the same key.
  const one = a.store.create(work, "A");
  const two = b.store.create(work, "B");
  await a.sync();
  await b.sync();
  await a.sync();
  assert.equal(a.note(one)?.order, b.note(one)?.order);
  assert.equal(a.note(two)?.order, b.note(two)?.order);

  // Moving the old note between the two tied notes used to ask for a key
  // between equal neighbours; it now re-spaces the folder instead of throwing.
  a.store.move(old, work, two);
  await a.sync();
  await b.sync();
  await a.sync();

  const order = (device) => device.store.load().notes.filter((n) => n.folder === work).map((n) => n.id);
  assert.deepEqual(order(a), order(b));
  assert.equal(order(a).length, 3);
});

test("an idle pass does not rewrite either workspace file", async () => {
  const remote = memoryRemote();
  const a = device(remote, { crdt: true });
  const b = device(remote, { crdt: true });
  a.store.createFolder("Work");
  a.store.create(null, "同步就好");

  await a.sync();
  await b.sync();
  const revs = new Map([...remote.files].filter(([name]) => isWorkspaceFile(name)).map(([name, f]) => [name, f.rev]));
  const count = remote.writes.length;
  await a.sync();
  await b.sync();

  assert.equal(remote.writes.length, count, "no uploads for an unchanged workspace");
  assert.deepEqual(new Map([...remote.files].filter(([name]) => isWorkspaceFile(name)).map(([name, f]) => [name, f.rev])), revs);
});

test("a base hash written before the workspace upgrade is still recognized", async () => {
  const remote = memoryRemote();
  const a = device(remote, { crdt: true });
  const work = a.store.createFolder("Work");
  const id = a.store.create(work, "原文");
  await a.sync();

  // The pre-workspace version hashed folder + body, not the body alone.
  a.base = {
    notes: {
      [id]: { ...a.base.notes[id], hash: hashOf(`${work}\n原文`) },
    },
  };
  const writes = remote.writes.length;
  const report = await a.sync();

  assert.equal(report.conflicts, 0);
  assert.equal(report.uploaded, 0);
  assert.equal(remote.writes.length, writes, "an unchanged note is not re-uploaded after the upgrade");
});

test("the first pass seeds workspace state from the legacy folders.json layout", async () => {
  const remote = memoryRemote();
  const legacy = device(remote);
  const work = legacy.store.createFolder("Work");
  const id = legacy.store.create(work, "舊筆記");
  await legacy.sync();
  assert.ok(remote.files.has("folders.json"));
  assert.ok(![...remote.files.keys()].some(isWorkspaceFile));

  const upgraded = device(remote, { crdt: true });
  await upgraded.sync();

  assert.equal(upgraded.folder("Work")?.id, work);
  assert.equal(upgraded.note(id)?.folder, work);
  assert.ok([...remote.files.keys()].some(isWorkspaceFile), "the upgrade writes the first device file");
  assert.ok(remote.files.has(`notes/${id}.md`), "bodies stay plain Markdown files");
});

test("a device that lost its local workspace state recovers it, and keeps offline edits", async () => {
  const remote = memoryRemote();
  const a = device(remote, { crdt: true });
  const b = device(remote, { crdt: true });
  const work = a.store.createFolder("Work");
  const id = a.store.create(work, "还在");
  await a.sync();
  await b.sync();

  // Organization made after the last sync, while this browser's workspace
  // storage is about to be lost. The notes index still has it.
  const local = b.store.createFolder("Local");
  const offline = b.store.create(work, "離線寫的");
  b.store.move(offline, local, null);

  // Same local notes, empty workspace storage (a cleared key, not a new note).
  const recovered = createWorkspace({ storage: memory() });
  const out = await syncNotes({ store: b.store, remote, base: {}, workspace: recovered });

  assert.equal(out.report.conflicts, 0);
  assert.equal(b.note(id)?.folder, work);
  assert.equal(b.store.read(id), "还在");
  assert.equal(b.folder("Local")?.id, local);
  assert.equal(b.note(offline)?.folder, local);
  assert.ok(remote.files.has(`notes/${offline}.md`), "the offline note body still reached the remote");
});
