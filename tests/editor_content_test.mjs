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
  const reads = [];
  let counter = 0;
  return {
    files,
    writes,
    reads,
    list: async () => [...files].map(([name, f]) => ({ name, rev: f.rev })),
    read: async (name) => { reads.push(name); return files.get(name)?.text ?? ""; },
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
    async sync(busy = () => false, options = {}) {
      const out = await syncNotes({
        store, remote, base, busy, workspace: ws, content, contentDevice: name, ...options,
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
  // The edit is an append-only delta chunk, not the note's whole history.
  assert.ok([...remote.files.keys()].some((name) => name.startsWith(`notes/${id}.b-`)));
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
  assert.ok([...remote.files.keys()].some((name) => name.startsWith(`notes/${id}.b-`)));

  a.store.delete(id);
  await a.sync();
  assert.ok(!remote.files.has(`notes/${id}.md`));
  assert.ok(!remote.files.has(`notes/${id}.seed.json`));
  assert.ok(![...remote.files.keys()].some((name) => name.startsWith(`notes/${id}.`)));
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

test("an edit uploads a small delta chunk, not the whole note", async () => {
  const remote = memoryRemote();
  const a = device(remote, "a");
  const b = device(remote, "b");
  const id = a.create("start");
  await a.sync();
  await b.sync();

  let text = a.content.markdown(id);
  for (let i = 0; i < 20; i++) {
    text += "字".repeat(10);
    a.edit(id, text);
    await a.sync();
  }
  const chunks = [...remote.files.entries()]
    .filter(([name]) => name.startsWith(`notes/${id}.a-`))
    .map(([, file]) => JSON.parse(file.text));
  assert.ok(chunks.length > 1, "one chunk per pass");
  const largest = Math.max(...chunks.map((chunk) => chunk.state.length));
  assert.ok(largest < a.content.state(id).length / 2, "a chunk is a delta, not the history");

  await b.sync();
  assert.equal(b.store.read(id), text);
});

test("compaction folds a device's chunks into one full state", async () => {
  const remote = memoryRemote();
  const a = device(remote, "a");
  const id = a.create("start");
  await a.sync();

  let text = a.content.markdown(id);
  for (let i = 0; i < 40; i++) {
    text += "字";
    a.edit(id, text);
    await a.sync();
  }
  const names = [...remote.files.keys()].filter((name) => name.startsWith(`notes/${id}.a-`));
  const seqs = names.map((name) => Number(name.match(/-(\d+)\.json$/)[1]));
  assert.ok(seqs.length <= 10, `chunks are bounded, got ${seqs.length}`);
  assert.ok(Math.min(...seqs) > 1, "the chunks before the fold were removed");
  const full = names.map((name) => JSON.parse(remote.files.get(name).text)).find((chunk) => chunk.state.length > 100);
  assert.ok(full, "the fold wrote a full state");
});

test("an idle pass does not read content it already applied", async () => {
  const remote = memoryRemote();
  const a = device(remote, "a");
  const b = device(remote, "b");
  const id = a.create("idle");
  await a.sync();
  await b.sync();

  remote.reads.length = 0;
  await a.sync();
  await b.sync();
  assert.deepEqual(remote.reads.filter((name) => name.startsWith("notes/")), []);

  // One edit is read once; the seed and the unchanged chunks are not re-read.
  a.edit(id, "idle again");
  await a.sync();
  remote.reads.length = 0;
  await b.sync();
  const contentReads = remote.reads.filter((name) => name.startsWith("notes/"));
  assert.ok(contentReads.every((name) => name.endsWith(".md") || name.startsWith(`notes/${id}.a-`)));
  assert.ok(!contentReads.includes(`notes/${id}.seed.json`));
});

test("a delete-only chunk still reaches the other device", async () => {
  const remote = memoryRemote();
  const a = device(remote, "a");
  const b = device(remote, "b");
  const id = a.create("alpha beta");
  await a.sync();
  await b.sync();

  b.edit(id, "alpha");
  await b.sync();
  const report = await a.sync();

  assert.ok(report.contentChanged.includes(id));
  assert.equal(a.content.markdown(id), "alpha");
  assert.equal(a.store.read(id), "alpha");
});

test("a checkpoint re-seeds a note once history dwarfs its text", async () => {
  const remote = memoryRemote();
  const a = device(remote, "a");
  const b = device(remote, "b");
  let text = "a".repeat(1000);
  const id = a.create(text);
  const opts = { checkpointBytes: 4096 };
  await a.sync(undefined, opts);
  await b.sync(undefined, opts);

  for (let i = 1; i <= 80; i++) {
    const at = (i * 37) % text.length;
    text = text.slice(0, at) + (text[at] === "a" ? "b" : "a") + text.slice(at + 1);
    a.edit(id, text);
    await a.sync(undefined, opts);
  }
  // A checkpoint happens on an idle pass, once the edits are merged.
  await a.sync(undefined, opts);

  assert.ok(remote.files.has(`notes/${id}.seed.1.json`));
  assert.equal(a.content.epoch(id), 1);
  // The old chunks are gone; the epoch-0 seed stays for older clients.
  assert.deepEqual([...remote.files.keys()].filter((name) => name.startsWith(`notes/${id}.a-`) && !name.endsWith(".1.json")), []);
  const chunkBytes = [...remote.files.entries()]
    .filter(([name]) => name.startsWith(`notes/${id}.a-`) && name.endsWith(".1.json"))
    .reduce((n, [, file]) => n + file.text.length, 0);
  assert.ok(chunkBytes < 4096, `checkpointed state is small, got ${chunkBytes}`);

  // A device with no local edits adopts the new epoch without a copy.
  const report = await b.sync(undefined, opts);
  assert.equal(report.conflicts, 0);
  assert.equal(b.content.epoch(id), 1);
  assert.equal(b.store.read(id), text);
  assert.equal(b.store.load().notes.filter((n) => n.id === id).length, 1);
});

test("a local edit across a checkpoint keeps both texts, then converges", async () => {
  const remote = memoryRemote();
  const a = device(remote, "a");
  const b = device(remote, "b");
  let text = "a".repeat(1000);
  const id = a.create(text);
  const opts = { checkpointBytes: 4096 };
  await a.sync(undefined, opts);
  await b.sync(undefined, opts);

  for (let i = 1; i <= 80; i++) {
    const at = (i * 37) % text.length;
    text = text.slice(0, at) + (text[at] === "a" ? "b" : "a") + text.slice(at + 1);
    a.edit(id, text);
    await a.sync(undefined, opts);
  }
  await a.sync(undefined, opts); // checkpoint
  assert.ok(remote.files.has(`notes/${id}.seed.1.json`));

  b.edit(id, "B edit");
  const report = await b.sync(undefined, opts);
  assert.equal(report.conflicts, 1);
  await a.sync(undefined, opts);
  await b.sync(undefined, opts);

  const bodies = (device) => device.store.load().notes.map((n) => device.store.read(n.id)).filter(Boolean).sort();
  assert.deepEqual(bodies(a), bodies(b));
  assert.ok(bodies(a).includes("B edit"));
  assert.ok(bodies(a).includes(text));
});

test("a full state file from an older client is still merged", async () => {
  const remote = memoryRemote();
  const a = device(remote, "a");
  const b = device(remote, "b");
  const id = a.create("base");
  await a.sync();
  await b.sync();

  b.edit(id, "base plus");
  await b.sync();
  // An older build writes one full state per device instead of chunks.
  for (const name of [...remote.files.keys()]) {
    if (name.startsWith(`notes/${id}.b-`)) remote.files.delete(name);
  }
  remote.files.set(`notes/${id}.b.json`, {
    text: JSON.stringify({ v: 1, device: "b", state: b.content.state(id) }),
    rev: "legacy",
  });

  await a.sync();
  assert.equal(a.store.read(id), "base plus");
  assert.equal(a.content.markdown(id), "base plus");
});
