// Checks the incremental Dropbox listing (site/editor/dropbox-list.js and the
// Dropbox remote in cloud.js) against an in-memory fake of the HTTP API:
// a pass after the first lists only what changed, this device's own uploads
// are not news, deletions (of folders too) drop files, a reset cursor falls
// back to a full list, and two devices syncing through it converge.
//   cd site && npm ci && node ../tests/editor_dropbox_list_test.mjs
import assert from "node:assert/strict";
import test from "node:test";
import { createCloud, dropbox } from "../site/editor/cloud.js";
import { applyEntries, emptyListing } from "../site/editor/dropbox-list.js";
import { createNotes } from "../site/editor/notes.js";
import { syncNotes } from "../site/editor/sync.js";

const memory = () => {
  const map = new Map();
  return {
    getItem: (k) => (map.has(k) ? map.get(k) : null),
    setItem: (k, v) => map.set(k, String(v)),
    removeItem: (k) => map.delete(k),
  };
};

/** Fake Dropbox: files, a change log the cursors index into, and a call log. */
function fakeDropbox({ pageSize = 1000 } = {}) {
  const files = new Map(); // path_lower -> { display, rev, text }
  const log = []; // entries in list_folder format
  const calls = [];
  let rev = 0;
  let resetBelow = 0;
  let wake = () => {};
  const json = (body, status = 200) => new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });
  const page = (entries, start, end) => ({
    entries: entries.slice(start, Math.min(end, start + pageSize)),
    has_more: start + pageSize < end,
  });
  const put = (display, text) => {
    const entry = { ".tag": "file", path_display: `/${display}`, path_lower: `/${display}`.toLowerCase(), rev: `r${++rev}` };
    files.set(entry.path_lower, { display, rev: entry.rev, text });
    log.push(entry);
    wake();
    return entry.rev;
  };
  const del = (display) => {
    const lower = `/${display}`.toLowerCase();
    for (const k of [...files.keys()]) if (k === lower || k.startsWith(`${lower}/`)) files.delete(k);
    log.push({ ".tag": "deleted", path_display: `/${display}`, path_lower: lower });
    wake();
  };
  async function fetch(url, init = {}) {
    const path = new URL(url).pathname.replace(/^\/2\//, "");
    calls.push(path);
    const body = init.body && typeof init.body === "string" ? JSON.parse(init.body) : null;
    const arg = init.headers?.["Dropbox-API-Arg"] ? JSON.parse(init.headers["Dropbox-API-Arg"]) : null;
    switch (path) {
      case "files/list_folder": {
        // A full listing: every file now, as one snapshot, then the log position.
        const all = [...files.values()].map((f) => ({ ".tag": "file", path_display: `/${f.display}`, path_lower: `/${f.display}`.toLowerCase(), rev: f.rev }));
        const p = page(all, 0, all.length);
        return json({ ...p, cursor: p.has_more ? `s${pageSize}:${log.length}` : `c${log.length}` });
      }
      case "files/list_folder/continue": {
        const snap = /^s(\d+):(\d+)$/.exec(body.cursor);
        if (snap) {
          const all = [...files.values()].map((f) => ({ ".tag": "file", path_display: `/${f.display}`, path_lower: `/${f.display}`.toLowerCase(), rev: f.rev }));
          const start = Number(snap[1]);
          const p = page(all, start, all.length);
          return json({ ...p, cursor: p.has_more ? `s${start + pageSize}:${snap[2]}` : `c${snap[2]}` });
        }
        const at = Number(body.cursor.slice(1));
        if (at < resetBelow) return json({ error_summary: "reset/..", error: { ".tag": "reset" } }, 409);
        const p = page(log, at, log.length);
        return json({ ...p, cursor: `c${at + p.entries.length}` });
      }
      case "files/list_folder/longpoll": {
        // Held until the log grows past the cursor (or briefly, then "no changes").
        const at = Number(body.cursor.slice(1));
        if (log.length <= at) {
          await new Promise((resolve) => {
            const timer = setTimeout(resolve, 50);
            wake = () => { clearTimeout(timer); resolve(); };
            init.signal?.addEventListener("abort", () => { clearTimeout(timer); resolve(); });
          });
        }
        return json({ changes: log.length > at });
      }
      case "files/download": {
        const f = files.get(arg.path.toLowerCase());
        return new Response(f?.text ?? "", { status: f ? 200 : 409 });
      }
      case "files/upload": {
        const have = files.get(arg.path.toLowerCase());
        const want = arg.mode[".tag"] === "update" ? arg.mode.update : null;
        if ((have?.rev ?? null) !== want) return json({ error_summary: "path/conflict/file/.." }, 409);
        return json({ rev: put(arg.path.slice(1), new TextDecoder().decode(init.body)) });
      }
      case "files/delete_v2": {
        if (!files.has(body.path.toLowerCase())) return json({ error_summary: "path_lookup/not_found/.." }, 409);
        del(body.path.slice(1));
        return json({});
      }
      default:
        throw new Error(`unexpected ${url}`);
    }
  }
  return { files, calls, fetch, put, del, resetCursors: () => { resetBelow = log.length + 1; } };
}

const account = () => ({ provider: "dropbox", access: "token", expires: Date.now() + 3_600_000 });

function withFake(fake, fn) {
  const real = globalThis.fetch;
  globalThis.fetch = fake.fetch;
  return Promise.resolve(fn()).finally(() => { globalThis.fetch = real; });
}

test("applyEntries tracks files by path_lower and drops a deleted folder's files", () => {
  const listing = emptyListing();
  assert.equal(applyEntries(listing, [
    { ".tag": "file", path_display: "/notes/A.md", path_lower: "/notes/a.md", rev: "1" },
    { ".tag": "file", path_display: "/notes/b.md", path_lower: "/notes/b.md", rev: "1" },
    { ".tag": "folder", path_display: "/notes", path_lower: "/notes" },
  ]), true);
  assert.equal(applyEntries(listing, [{ ".tag": "file", path_display: "/notes/A.md", path_lower: "/notes/a.md", rev: "1" }]), false);
  assert.equal(applyEntries(listing, [{ ".tag": "deleted", path_display: "/Notes", path_lower: "/notes" }]), true);
  assert.deepEqual(listing.files, {});
});

test("after the first pass a list asks only for changes, and its own uploads are not news", async () => {
  const fake = fakeDropbox();
  fake.put("folders.json", "{}");
  fake.put("notes/a.md", "a");
  const acct = account();
  await withFake(fake, async () => {
    const first = dropbox(acct, () => {});
    assert.deepEqual((await first.list()).map((f) => f.name).sort(), ["folders.json", "notes/a.md"]);
    assert.equal(first.changed, true);
    assert.deepEqual(fake.calls, ["files/list_folder"]);

    // This device writes and deletes; the next pass (a new remote, as each pass makes) hears nothing new.
    const rev = await first.write("notes/b.md", "b", null);
    await first.remove("notes/a.md");
    fake.calls.length = 0;
    const second = dropbox(acct, () => {});
    const listed = await second.list();
    assert.deepEqual(fake.calls, ["files/list_folder/continue"]);
    assert.equal(second.changed, false);
    assert.deepEqual(listed.map((f) => [f.name, f.rev]).sort(), [["folders.json", "r1"], ["notes/b.md", rev]]);

    // Another device's write is news, and shows up.
    fake.put("notes/c.md", "c");
    const third = dropbox(acct, () => {});
    assert.ok((await third.list()).some((f) => f.name === "notes/c.md"));
    assert.equal(third.changed, true);
  });
});

test("a reset cursor falls back to a full listing", async () => {
  const fake = fakeDropbox();
  fake.put("notes/a.md", "a");
  const acct = account();
  await withFake(fake, async () => {
    await dropbox(acct, () => {}).list();
    fake.put("notes/b.md", "b");
    fake.resetCursors();
    fake.calls.length = 0;
    const remote = dropbox(acct, () => {});
    assert.deepEqual((await remote.list()).map((f) => f.name).sort(), ["notes/a.md", "notes/b.md"]);
    assert.deepEqual(fake.calls, ["files/list_folder/continue", "files/list_folder"]);
    assert.equal(remote.changed, true);
  });
});

test("listings that span several pages are followed to the end", async () => {
  const fake = fakeDropbox({ pageSize: 2 });
  for (let i = 0; i < 5; i++) fake.put(`notes/n${i}.md`, `${i}`);
  const acct = account();
  await withFake(fake, async () => {
    assert.equal((await dropbox(acct, () => {}).list()).length, 5);
    for (let i = 5; i < 10; i++) fake.put(`notes/n${i}.md`, `${i}`);
    fake.del("notes/n0.md");
    assert.equal((await dropbox(acct, () => {}).list()).length, 9);
  });
});

test("two devices syncing through the incremental listing converge", async () => {
  const fake = fakeDropbox();
  const devices = [0, 1].map(() => {
    const store = createNotes(memory());
    const acct = account();
    let base = {};
    return {
      store,
      async sync() {
        const out = await syncNotes({ store, remote: dropbox(acct, () => {}), base });
        base = out.base;
        return out.report;
      },
      bodies: () => store.snapshot().notes.map((n) => n.body).filter(Boolean).sort(),
    };
  });
  const [a, b] = devices;
  await withFake(fake, async () => {
    const id = a.store.create(null, "第一版");
    await a.sync();
    await b.sync();
    assert.deepEqual(b.bodies(), ["第一版"]);
    b.store.write(id, "第二版");
    b.store.create(null, "另一篇");
    await b.sync();
    fake.calls.length = 0;
    await a.sync();
    assert.ok(!fake.calls.includes("files/list_folder"), "a's later passes list incrementally");
    assert.deepEqual(a.bodies(), ["另一篇", "第二版"]);
    a.store.delete(id);
    await a.sync();
    await b.sync();
    assert.deepEqual(b.bodies(), ["另一篇"]);
    assert.deepEqual(a.bodies(), b.bodies());
  });
});

test("the watcher starts a sync for another device's change, not for this device's own upload", async () => {
  const fake = fakeDropbox();
  const storage = memory();
  const realStorage = globalThis.localStorage;
  globalThis.localStorage = storage;
  const store = createNotes(memory());
  const cloud = createCloud({ notes: store, busy: () => false, onChange: () => {} });
  storage.setItem("misstype-editor-sync", JSON.stringify({ account: { ...account(), connected: 1 }, base: {}, last: 0 }));
  const until = async (cond) => {
    for (let i = 0; i < 100 && !cond(); i++) await new Promise((r) => setTimeout(r, 10));
  };
  let heard = 0;
  try {
    await withFake(fake, async () => {
      const id = store.create(null, "本機");
      await cloud.sync();
      cloud.watch(() => { heard++; });
      // This device uploads an edit: the longpoll reports it, the quiet check finds nothing new.
      store.write(id, "本機改過");
      await cloud.sync();
      await until(() => fake.calls.filter((c) => c === "files/list_folder/continue").length >= 2);
      await new Promise((r) => setTimeout(r, 100));
      assert.equal(heard, 0);
      // Another device writes: heard within a moment.
      fake.put("notes/other.md", "別台");
      await until(() => heard > 0);
      assert.equal(heard, 1);
    });
  } finally {
    cloud.unwatch();
    globalThis.localStorage = realStorage;
  }
});
