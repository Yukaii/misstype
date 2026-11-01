// Checks the document CRDT (site/editor/content.js + content-sync.js): a note's
// Y.Doc is seeded once, each device writes its own static state file, and two
// concurrent edits merge into one note instead of the old duplicate copy.
//   cd site && npm ci && node ../tests/editor_content_test.mjs
import assert from "node:assert/strict";
import test from "node:test";
import { createNotes } from "../site/editor/notes.js";
import { createWorkspace } from "../site/editor/workspace.js";
import { createContent } from "../site/editor/content.js";
import { syncNotes } from "../site/editor/sync.js";

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

function device(remote, name) {
  let ws = null;
  const store = createNotes(memory(), { onWorkspace: (op) => ws?.applyLocal(op) });
  const content = createContent({ notes: store, storage: memory() });
  ws = createWorkspace({ storage: memory() });
  ws.ensure(store.workspaceState());
  let base = {};
  return {
    store,
    content,
    get ws() { return ws; },
    create(markdown = "") {
      const id = store.create(null, markdown);
      content.open(id); // the editor opens a new note immediately
      return id;
    },
    edit(id, markdown) {
      content.replaceMarkdown(id, markdown);
      store.write(id, markdown);
    },
    async sync(busy) {
      const out = await syncNotes({
        store, remote, base, busy, workspace: ws, content, contentDevice: name,
      });
      base = out.base;
      return out.report;
    },
  };
}

test("Markdown round-trips through the note CRDT", () => {
  const a = device(memoryRemote(), "a");
  const markdown = "# 標題\n\n- 一\n- 二\n\n**粗體**";
  const id = a.create(markdown);
  // The CRDT stores the ProseMirror document; Markdown is its normalized export.
  assert.equal(a.content.markdown(id), a.content.normalize(markdown));
  assert.match(a.content.markdown(id), /# 標題/);
  assert.match(a.content.markdown(id), /\*\*粗體\*\*/);
});

test("two devices sharing a seed merge concurrent edits into one note", async () => {
  const remote = memoryRemote();
  const a = device(remote, "a");
  const b = device(remote, "b");
  const id = a.create("alpha beta gamma");
  await a.sync();
  await b.sync();

  assert.ok(remote.files.has(`notes/${id}.seed.json`));
  assert.ok(!remote.files.has(`notes/${id}.md.seed.json`));
  assert.equal(b.store.read(id), "alpha beta gamma");

  // Non-overlapping edits: prepend on B, append on A.
  b.edit(id, "B: alpha beta gamma");
  await b.sync();
  a.edit(id, "alpha beta gamma A");
  const report = await a.sync();
  await b.sync();

  assert.equal(report.merged, 1);
  assert.equal(report.conflicts, 0);
  assert.equal(a.store.load().notes.filter((n) => n.id === id).length, 1);
  assert.equal(b.store.load().notes.filter((n) => n.id === id).length, 1);
  const text = a.store.read(id);
  assert.match(text, /B: /);
  assert.match(text, / A$/);
  assert.equal(b.store.read(id), text);
});

test("an independently seeded but untouched document adopts the first seed", async () => {
  const remote = memoryRemote();
  const a = device(remote, "a");
  const b = device(remote, "b");
  const id = a.create("same");
  await a.sync();

  // B opened the note and made its own Y.Doc before it saw A's seed.
  b.store.put({ id, folder: null, updated: Date.now(), body: "same" });
  b.content.open(id);
  const report = await b.sync();

  assert.equal(report.conflicts, 0);
  assert.equal(report.merged, 0);
  assert.equal(b.content.linked(id), true);
  assert.equal(b.store.load().notes.filter((n) => n.id === id).length, 1);
  assert.equal(b.store.read(id), "same");
});

test("a remote edit reaches a device whose body is still the old base", async () => {
  const remote = memoryRemote();
  const a = device(remote, "a");
  const b = device(remote, "b");
  const id = a.create("base");
  await a.sync();
  await b.sync();
  assert.equal(b.content.linked(id), true);

  a.edit(id, "remote edit");
  await a.sync();
  const report = await b.sync();

  assert.equal(report.conflicts, 0);
  assert.equal(report.merged, 0);
  assert.equal(b.store.read(id), "remote edit");
  assert.equal(b.store.load().notes.filter((n) => n.id === id).length, 1);
});

test("a one-sided edit still uploads a body and a per-device state", async () => {
  const remote = memoryRemote();
  const a = device(remote, "a");
  const b = device(remote, "b");
  const id = a.create("one");
  await a.sync();
  await b.sync();
  b.edit(id, "one two");
  await b.sync();

  assert.ok(remote.files.has(`notes/${id}.seed.json`));
  assert.ok(remote.files.has(`notes/${id}.b.json`));
  await a.sync();
  assert.equal(a.store.read(id), "one two");
  assert.equal(a.content.markdown(id), "one two");
});

test("a note conflict resolves through the shared seed without a copy", async () => {
  const remote = memoryRemote();
  const a = device(remote, "a");
  const b = device(remote, "b");
  const id = a.create("left right");
  await a.sync();
  await b.sync();
  a.edit(id, "LEFT right");
  b.edit(id, "left RIGHT");
  await a.sync();
  const report = await b.sync();
  await a.sync();

  assert.equal(report.conflicts, 0);
  assert.equal(report.merged, 1);
  assert.equal(a.store.load().notes.filter((n) => n.id === id).length, 1);
  assert.equal(b.store.load().notes.filter((n) => n.id === id).length, 1);
  assert.equal(a.store.read(id), b.store.read(id));
  assert.match(a.store.read(id), /LEFT/);
  assert.match(a.store.read(id), /RIGHT/);
});

test("deleting a note removes its seed and state files", async () => {
  const remote = memoryRemote();
  const a = device(remote, "a");
  const b = device(remote, "b");
  const id = a.create("delete me");
  await a.sync();
  await b.sync();
  b.edit(id, "delete me now");
  await b.sync();
  await a.sync();
  assert.ok(remote.files.has(`notes/${id}.b.json`));

  a.store.delete(id);
  await a.sync();
  assert.ok(!remote.files.has(`notes/${id}.md`));
  assert.ok(!remote.files.has(`notes/${id}.seed.json`));
  assert.ok(!remote.files.has(`notes/${id}.a.json`));
  assert.ok(!remote.files.has(`notes/${id}.b.json`));
  await b.sync();
  assert.ok(!b.store.load().notes.some((n) => n.id === id));
});

test("a pre-seed local edit keeps both texts, then rebases for later merges", async () => {
  const remote = memoryRemote();
  const a = device(remote, "a");
  const b = device(remote, "b");
  const id = a.create("base");
  await a.sync();

  // B has the note text from before the seed reached it: an independent Y.Doc.
  b.store.put({ id, folder: null, updated: Date.now(), body: "base" });
  b.content.open(id);
  b.edit(id, "B edit");
  a.edit(id, "A edit");
  await a.sync();
  const report = await b.sync();
  await a.sync();

  assert.equal(report.conflicts, 1);
  assert.equal(report.merged, 0);
  assert.equal(a.store.load().notes.filter((n) => n.id === id).length, 1);
  assert.equal(b.store.load().notes.filter((n) => n.id === id).length, 1);
  assert.equal(a.store.read(id), "B edit");
  assert.equal(b.store.read(id), "B edit");
  const bodies = (device) => device.store.load().notes.map((n) => device.store.read(n.id)).filter(Boolean).sort();
  assert.deepEqual(bodies(a), ["A edit", "B edit"]);
  assert.deepEqual(bodies(b), ["A edit", "B edit"]);
  // The kept local note now shares the remote seed, so the next conflict merges.
  assert.equal(b.content.linked(id), true);
});

test("an edit beats a delete with content state present", async () => {
  const remote = memoryRemote();
  const a = device(remote, "a");
  const b = device(remote, "b");
  const id = a.create("keep");
  await a.sync();
  await b.sync();

  a.store.delete(id);
  b.edit(id, "keep this");
  await a.sync();
  await b.sync();
  await a.sync();

  assert.equal(a.store.read(id), "keep this");
  assert.equal(b.store.read(id), "keep this");
  assert.equal(a.store.load().notes.filter((n) => n.id === id).length, 1);
});
