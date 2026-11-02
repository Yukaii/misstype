// Measures the editor's cloud sync: how a note's CRDT state, the bytes a pass
// uploads, and the reads a pass needs grow with edit history, note count and
// device count. The remote is in memory but counts every call and byte, so the
// same script compares a change against the previous layout.
//
//   node tools/editor_sync_bench.mjs
//   node tools/editor_sync_bench.mjs --json
//
// Scenarios:
//   growth   one note, one device, N edits, one sync after each
//   idle     two devices after the growth run, ten idle passes each
//   many     100 notes, two devices, one edit, one more pass each
//
// What to read: "state" is the per-device content file the note uploads (the
// whole Y.Doc state today); "up/read" are bytes written/read by a pass. A pass
// that changes nothing should read and write nothing.

import { createNotes } from "../site/editor/notes.js";
import { createWorkspace } from "../site/editor/workspace.js";
import { createContent } from "../site/editor/content.js";
import { syncNotes } from "../site/editor/sync.js";

const CHECK = process.argv.includes("--check");
const EDITS = Number(process.env.EDITS || (CHECK ? 1000 : 200));
const NOTES = Number(process.env.NOTES || 100);
const CHARS = Number(process.env.CHARS || 10);
const CHURN = Number(process.env.CHURN || (CHECK ? 2000 : 200));
const JSON_OUT = process.argv.includes("--json");

const memory = () => {
  const map = new Map();
  return {
    map,
    getItem: (k) => (map.has(k) ? map.get(k) : null),
    setItem: (k, v) => map.set(k, String(v)),
    removeItem: (k) => map.delete(k),
    bytes: () => [...map.values()].reduce((n, v) => n + Buffer.byteLength(v), 0),
  };
};

/** In-memory remote that counts calls and bytes like a real provider would bill them. */
function memoryRemote() {
  const files = new Map();
  const stats = { lists: 0, reads: 0, writes: 0, removes: 0, readBytes: 0, writeBytes: 0, contentReadBytes: 0, contentWriteBytes: 0 };
  let counter = 0;
  const reset = () => {
    for (const k of Object.keys(stats)) stats[k] = 0;
  };
  return {
    files,
    stats,
    reset,
    async list() {
      stats.lists++;
      return [...files].map(([name, f]) => ({ name, rev: f.rev }));
    },
    async read(name) {
      stats.reads++;
      const text = files.get(name)?.text ?? "";
      stats.readBytes += Buffer.byteLength(text);
      if (name.startsWith("notes/") && name.endsWith(".json")) stats.contentReadBytes += Buffer.byteLength(text);
      return text;
    },
    async write(name, text, rev) {
      const have = files.get(name);
      if ((have?.rev ?? null) !== rev) throw Object.assign(new Error("conflict"), { conflict: true });
      stats.writes++;
      stats.writeBytes += Buffer.byteLength(text);
      // Content files are notes/*.json (seed, chunks); the body is notes/*.md.
      if (name.startsWith("notes/") && name.endsWith(".json")) stats.contentWriteBytes += Buffer.byteLength(text);
      files.set(name, { text, rev: `r${++counter}` });
      return `r${counter}`;
    },
    async remove(name) {
      stats.removes++;
      files.delete(name);
    },
    size() {
      return [...files.values()].reduce((n, f) => n + Buffer.byteLength(f.text), 0);
    },
  };
}

function device(remote, name) {
  let ws = null;
  const storage = memory();
  const store = createNotes(storage, { onWorkspace: (op) => ws?.applyLocal(op) });
  const content = createContent({ notes: store, storage });
  ws = createWorkspace({ storage });
  ws.ensure(store.workspaceState());
  let base = {};
  return {
    store,
    content,
    storage,
    create: (markdown = "") => {
      const id = store.create(null, markdown);
      content.open(id);
      return id;
    },
    edit(id, markdown) {
      content.replaceMarkdown(id, markdown);
      store.write(id, markdown);
    },
    async sync() {
      const out = await syncNotes({ store, remote, base, busy: () => false, workspace: ws, content, contentDevice: name });
      base = out.base;
      return out.report;
    },
    base: () => base,
  };
}

const ms = (start) => Number(process.hrtime.bigint() - start) / 1e6;
const kb = (n) => `${(n / 1024).toFixed(1)} kB`;

/** This device's content files for one note (legacy state or chunks), not the seed or the body. */
function stateBytes(remote, id, deviceName) {
  let bytes = 0;
  for (const [name, file] of remote.files) {
    if (name.startsWith(`notes/${id}.${deviceName}`)) bytes += Buffer.byteLength(file.text);
  }
  return bytes;
}

/** Every content file for a note (seed, chunks, legacy), not the Markdown body. */
function contentBytes(remote, id) {
  let bytes = 0;
  for (const [name, file] of remote.files) {
    if (name.startsWith(`notes/${id}.`) && name.endsWith(".json")) bytes += Buffer.byteLength(file.text);
  }
  return bytes;
}

function chunkCount(remote, id, deviceName) {
  return [...remote.files.keys()].filter((name) => name.startsWith(`notes/${id}.${deviceName}-`)).length;
}

async function pass(remote, dev) {
  remote.reset();
  const start = process.hrtime.bigint();
  await dev.sync();
  return { ms: ms(start), ...remote.stats };
}

const out = { config: { EDITS, NOTES, CHARS, CHURN }, growth: [], churn: [], idle: [], many: null };

// ------------------------------------------------------------------ growth
{
  const remote = memoryRemote();
  const a = device(remote, "a");
  const id = a.create("start");
  await a.sync();
  let markdown = a.content.markdown(id);
  for (let i = 1; i <= EDITS; i++) {
    markdown += "字".repeat(CHARS);
    a.edit(id, markdown);
    const p = await pass(remote, a);
    if (i === 1 || i === 10 || i === 50 || i === 100 || i === 200 || i === 500 || i === 1000) {
      out.growth.push({
        edit: i,
        text: Buffer.byteLength(markdown),
        state: stateBytes(remote, id, "a"),
        chunks: chunkCount(remote, id, "a"),
        remoteTotal: remote.size(),
        local: a.storage.bytes(),
        up: p.writeBytes,
        stateUp: p.contentWriteBytes,
        stateRead: p.contentReadBytes,
        read: p.readBytes,
        reads: p.reads,
        writes: p.writes,
        ms: p.ms,
      });
    }
  }
  // A pass with no local change must not upload or re-read the note.
  const idleA = await pass(remote, a);
  out.growth.push({
    edit: "idle",
    text: Buffer.byteLength(markdown),
    state: stateBytes(remote, id, "a"),
    chunks: chunkCount(remote, id, "a"),
    remoteTotal: remote.size(),
    local: a.storage.bytes(),
    up: idleA.writeBytes,
    stateUp: idleA.contentWriteBytes,
    stateRead: idleA.contentReadBytes,
    read: idleA.readBytes,
    reads: idleA.reads,
    writes: idleA.writes,
    ms: idleA.ms,
  });

  // ---------------------------------------------------------------- idle
  const b = device(remote, "b");
  await b.sync();
  const idle = [];
  for (let i = 0; i < 10; i++) idle.push(await pass(remote, i % 2 ? a : b));
  out.idle.push({
    device: "a/b",
    passes: idle.length,
    reads: idle.reduce((n, p) => n + p.reads, 0),
    readBytes: idle.reduce((n, p) => n + p.readBytes, 0),
    writes: idle.reduce((n, p) => n + p.writes, 0),
    writeBytes: idle.reduce((n, p) => n + p.writeBytes, 0),
    ms: idle.reduce((n, p) => n + p.ms, 0) / idle.length,
  });
}

// ------------------------------------------------------------------ churn
// Rewriting the same text (a fixed-size note, one character changed per pass)
// leaves tombstones: state should stay proportional to the text, not to edits.
{
  const remote = memoryRemote();
  const a = device(remote, "a");
  let markdown = "a".repeat(1000);
  const id = a.create(markdown);
  await a.sync();
  for (let i = 1; i <= CHURN; i++) {
    const at = (i * 37) % markdown.length;
    markdown = markdown.slice(0, at) + (markdown[at] === "a" ? "b" : "a") + markdown.slice(at + 1);
    a.edit(id, markdown);
    const p = await pass(remote, a);
    if (i === 1 || i === 10 || i === 50 || i === 100 || i === 200 || i === 500 || i === 1000 || i === 2000) {
      out.churn.push({
        edit: i,
        text: Buffer.byteLength(markdown),
        state: contentBytes(remote, id),
        chunks: chunkCount(remote, id, "a"),
        local: a.storage.bytes(),
        stateUp: p.contentWriteBytes,
        stateRead: p.contentReadBytes,
        ms: p.ms,
      });
    }
  }
  // An idle pass is where a bloated history gets a new seed.
  const idle = await pass(remote, a);
  out.churn.push({
    edit: "idle",
    text: Buffer.byteLength(markdown),
    state: contentBytes(remote, id),
    chunks: chunkCount(remote, id, "a"),
    local: a.storage.bytes(),
    stateUp: idle.contentWriteBytes,
    stateRead: idle.contentReadBytes,
    ms: idle.ms,
  });
}

// ------------------------------------------------------------------- many
{
  const remote = memoryRemote();
  const a = device(remote, "a");
  const ids = [];
  for (let i = 0; i < NOTES; i++) ids.push(a.create(`note ${i}`));
  await a.sync();
  const b = device(remote, "b");
  const first = await pass(remote, b);
  await pass(remote, a);
  const target = ids[0];
  a.edit(target, "note 0 changed");
  const changed = await pass(remote, a);
  const idle = await pass(remote, b);
  await pass(remote, a);
  await pass(remote, b);
  const settled = await pass(remote, a);
  out.many = {
    notes: NOTES,
    files: remote.files.size,
    remoteTotal: remote.size(),
    firstPass: { reads: first.reads, readBytes: first.readBytes, writes: first.writes, ms: first.ms },
    editPass: { reads: changed.reads, readBytes: changed.readBytes, writes: changed.writes, writeBytes: changed.writeBytes, ms: changed.ms },
    idlePass: { reads: idle.reads, readBytes: idle.readBytes, writes: idle.writes, ms: idle.ms },
    settled: { reads: settled.reads, readBytes: settled.readBytes, contentRead: settled.contentReadBytes, writes: settled.writes, ms: settled.ms },
  };
}

if (JSON_OUT) {
  console.log(JSON.stringify(out, null, 2));
  process.exit(0);
}

if (CHECK) {
  const idle = out.growth.find((r) => r.edit === "idle");
  const last = out.growth.filter((r) => typeof r.edit === "number").at(-1);
  const churnIdle = out.churn.at(-1);
  const many = out.many;
  const checks = [
    ["idle pass reads no content", idle.stateRead === 0, `${idle.stateRead} bytes`],
    ["idle pass writes no content", idle.stateUp === 0, `${idle.stateUp} bytes`],
    ["an edit uploads a delta, not history", last.stateUp < 4096, `${last.stateUp} bytes`],
    ["a checkpoint folds churn history", churnIdle.state < 4 * churnIdle.text, `${(churnIdle.state / churnIdle.text).toFixed(2)}x text`],
    ["many notes: a settled pass reads no content", many.settled.contentRead === 0, `${many.settled.contentRead} bytes`],
  ];
  let failed = 0;
  for (const [name, ok, detail] of checks) {
    console.log(`${ok ? "ok  " : "FAIL"} ${name} (${detail})`);
    if (!ok) failed++;
  }
  process.exit(failed ? 1 : 0);
}

const row = (c) => c.map((v) => String(v)).join("\t");
console.log(`editor sync bench — ${EDITS} edits of ${CHARS} chars, ${NOTES} notes\n`);
console.log("growth (one note, one device)");
console.log(row(["edit", "text", "state", "chunks", "remote", "local", "up", "stateUp", "read", "reads", "writes", "ms"]));
for (const r of out.growth) {
  console.log(row([r.edit, kb(r.text), kb(r.state), r.chunks, kb(r.remoteTotal), kb(r.local), kb(r.up), kb(r.stateUp), kb(r.read), r.reads, r.writes, r.ms.toFixed(1)]));
}
console.log("\nchurn (1 kB note, one character rewritten per edit)");
console.log(row(["edit", "text", "state", "state/text", "chunks", "local", "stateUp", "ms"]));
for (const r of out.churn) {
  console.log(row([r.edit, kb(r.text), kb(r.state), (r.state / r.text).toFixed(2), r.chunks, kb(r.local), kb(r.stateUp), r.ms.toFixed(1)]));
}
console.log("\nidle passes (two devices, ten passes)");
for (const r of out.idle) {
  console.log(row([`${r.passes} passes`, `${r.reads} reads`, kb(r.readBytes), `${r.writes} writes`, kb(r.writeBytes), `${r.ms.toFixed(1)} ms/pass`]));
}
console.log(`\nmany notes (${NOTES} notes, two devices)`);
const m = out.many;
console.log(row(["files", "remote", "first reads", "first writes", "edit reads", "edit writes", "idle reads", "idle writes"]));
console.log(row([m.files, kb(m.remoteTotal), m.firstPass.reads, m.firstPass.writes, m.editPass.reads, m.editPass.writes, m.idlePass.reads, m.idlePass.writes]));
