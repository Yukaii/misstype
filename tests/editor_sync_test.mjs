// Checks the editor's cloud sync (site/editor/sync.js) with two devices on one
// in-memory remote: changes and deletions go across, an edit beats a delete,
// edits on both sides keep both texts, folders merge, and a write that lost a
// race is retried on the next pass instead of overwriting.
//   cd site && npm ci && node ../tests/editor_sync_test.mjs
import assert from "node:assert/strict";
import test from "node:test";
import { createNotes } from "../site/editor/notes.js";
import { formatNote, mergeFolders, parseNote, syncNotes } from "../site/editor/sync.js";

const memory = () => {
  const map = new Map();
  return { getItem: (k) => (map.has(k) ? map.get(k) : null), setItem: (k, v) => map.set(k, String(v)), removeItem: (k) => map.delete(k) };
};

function memoryRemote() {
  const files = new Map();
  let counter = 0;
  return {
    files,
    list: async () => [...files].map(([name, f]) => ({ name, rev: f.rev })),
    read: async (name) => files.get(name).text,
    async write(name, text, rev) {
      const have = files.get(name);
      if ((have?.rev ?? null) !== rev) throw Object.assign(new Error("conflict"), { conflict: true });
      files.set(name, { text, rev: `r${++counter}` });
      return `r${counter}`;
    },
    remove: async (name) => { files.delete(name); },
  };
}

function device(remote) {
  const store = createNotes(memory());
  let base = {};
  return {
    store,
    async sync(busy) {
      const out = await syncNotes({ store, remote, base, busy });
      base = out.base;
      return out.report;
    },
    bodies: () => store.snapshot().notes.map((n) => n.body).filter(Boolean).sort(),
  };
}

test("note files keep the Markdown as is behind a small front matter", () => {
  const body = "---\n\n# 標題\n\n內文\n";
  const text = formatNote({ folder: "f1", updated: Date.UTC(2026, 9, 25), body });
  assert.deepEqual(parseNote(text), { folder: "f1", updated: Date.UTC(2026, 9, 25), body });
  // A Markdown file dropped into the folder by hand is a top-level note.
  assert.deepEqual(parseNote("---\n\nplain"), { folder: null, updated: 0, body: "---\n\nplain" });
});

test("a new note goes across; a fresh empty note does not", async () => {
  const remote = memoryRemote();
  const a = device(remote);
  const b = device(remote);
  a.store.write(a.store.load().current, "# 購物清單\n\n牛奶");
  await a.sync();
  assert.equal([...remote.files.keys()].filter((n) => n.startsWith("notes/")).length, 1);
  await b.sync();
  assert.deepEqual(b.bodies(), ["# 購物清單\n\n牛奶"]);
  // b's own blank first note stayed local.
  assert.equal(b.store.load().notes.length, 2);
  assert.equal([...remote.files.keys()].filter((n) => n.startsWith("notes/")).length, 1);
});

test("edits and deletions go across", async () => {
  const remote = memoryRemote();
  const a = device(remote);
  const b = device(remote);
  const id = a.store.create(null, "第一版");
  await a.sync();
  await b.sync();
  b.store.write(id, "第二版");
  await b.sync();
  const report = await a.sync();
  assert.deepEqual(report.changed, [id]);
  assert.equal(a.store.read(id), "第二版");
  a.store.delete(id);
  await a.sync();
  assert.ok(!remote.files.has(`notes/${id}.md`));
  await b.sync();
  assert.ok(!b.store.load().notes.some((n) => n.id === id));
  // Deleting the last synced note leaves no note files, and that is not mistaken for a wiped folder.
  await a.sync();
  assert.ok(![...remote.files.keys()].some((n) => n.startsWith("notes/")));
});

test("an edit beats a delete, either way round", async () => {
  const remote = memoryRemote();
  const a = device(remote);
  const b = device(remote);
  const id = a.store.create(null, "原文");
  await a.sync();
  await b.sync();
  a.store.delete(id);
  b.store.write(id, "改過");
  await a.sync();
  await b.sync();
  assert.equal(b.store.read(id), "改過");
  assert.ok(remote.files.has(`notes/${id}.md`));
  await a.sync();
  assert.equal(a.store.read(id), "改過");
});

test("edits on both sides keep both texts", async () => {
  const remote = memoryRemote();
  const a = device(remote);
  const b = device(remote);
  const id = a.store.create(null, "原文");
  await a.sync();
  await b.sync();
  a.store.write(id, "A 的版本");
  b.store.write(id, "B 的版本");
  await a.sync();
  const report = await b.sync();
  assert.equal(report.conflicts, 1);
  assert.equal(b.store.read(id), "B 的版本");
  assert.deepEqual(b.bodies(), ["A 的版本", "B 的版本"]);
  await a.sync();
  assert.deepEqual(a.bodies(), ["A 的版本", "B 的版本"]);
  assert.equal(a.store.read(id), "B 的版本");
});

test("a note with unsaved edits on screen is not replaced", async () => {
  const remote = memoryRemote();
  const a = device(remote);
  const b = device(remote);
  const id = a.store.create(null, "原文");
  await a.sync();
  await b.sync();
  b.store.write(id, "遠端改的");
  await b.sync();
  await a.sync((n) => n === id);
  assert.equal(a.store.read(id), "原文");
  // Once saved, the local edit meets the remote one as a conflict: both kept.
  a.store.write(id, "本機改的");
  await a.sync();
  assert.deepEqual(a.bodies(), ["本機改的", "遠端改的"]);
});

test("folders merge and notes follow their folder", async () => {
  const remote = memoryRemote();
  const a = device(remote);
  const b = device(remote);
  const work = a.store.createFolder("Work");
  const id = a.store.create(work, "會議紀錄");
  await a.sync();
  await b.sync();
  assert.deepEqual(b.store.snapshot().folders, [{ id: work, name: "Work" }]);
  assert.equal(b.store.snapshot().notes.find((n) => n.id === id).folder, work);
  // Rename on one side, add on the other.
  b.store.renameFolder(work, "工作");
  const home = a.store.createFolder("Home");
  await a.sync();
  await b.sync();
  await a.sync();
  assert.deepEqual(a.store.snapshot().folders.map((f) => f.name), ["工作", "Home"]);
  assert.deepEqual(b.store.snapshot().folders.map((f) => f.name), ["工作", "Home"]);
  // Deleting a folder moves its notes to the top level everywhere.
  a.store.deleteFolder(work);
  await a.sync();
  await b.sync();
  assert.deepEqual(b.store.snapshot().folders.map((f) => f.id), [home]);
  assert.equal(b.store.snapshot().notes.find((n) => n.id === id).folder, null);
});

test("folder merge: delete loses to a rename, both renamed keeps the local name", () => {
  const base = [{ id: "x", name: "X" }, { id: "y", name: "Y" }];
  assert.deepEqual(mergeFolders(base, [{ id: "y", name: "Y" }], [{ id: "x", name: "X2" }, { id: "y", name: "Y" }]),
    [{ id: "y", name: "Y" }, { id: "x", name: "X2" }]);
  assert.deepEqual(mergeFolders(base, [{ id: "x", name: "本機" }, { id: "y", name: "Y" }], [{ id: "x", name: "遠端" }, { id: "y", name: "Y" }]),
    [{ id: "x", name: "本機" }, { id: "y", name: "Y" }]);
});

test("a write that lost a race is retried next pass, not forced", async () => {
  const remote = memoryRemote();
  const a = device(remote);
  const id = a.store.create(null, "原文");
  await a.sync();
  a.store.write(id, "本機");
  // Another device writes between our list() and write().
  const list = remote.list;
  remote.list = async () => {
    const files = await list();
    remote.files.set(`notes/${id}.md`, { text: formatNote({ folder: null, updated: 1, body: "別台" }), rev: "other" });
    return files;
  };
  await a.sync();
  remote.list = list;
  assert.equal(parseNote(remote.files.get(`notes/${id}.md`).text).body, "別台");
  await a.sync();
  assert.deepEqual(a.bodies(), ["別台", "本機"]);
});

test("an emptied remote folder is filled again, not mirrored as deletions", async () => {
  const remote = memoryRemote();
  const a = device(remote);
  const id = a.store.create(null, "留著");
  a.store.createFolder("Work");
  await a.sync();
  remote.files.clear();
  await a.sync();
  assert.equal(a.store.read(id), "留著");
  assert.deepEqual(a.store.snapshot().folders.map((f) => f.name), ["Work"]);
  assert.ok(remote.files.has(`notes/${id}.md`) && remote.files.has("folders.json"));
});
