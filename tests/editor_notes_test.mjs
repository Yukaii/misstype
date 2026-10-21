// Checks the editor's notes store (site/editor/notes.js): the single note of
// earlier versions is kept, titles follow the first line, folders stay one
// level deep and deleting never leaves the editor without a note.
//   cd site && npm ci && node ../tests/editor_notes_test.mjs
import assert from "node:assert/strict";
import test from "node:test";
import { createNotes, titleOf } from "../site/editor/notes.js";

const memory = (init = {}) => {
  const map = new Map(Object.entries(init));
  return {
    getItem: (k) => (map.has(k) ? map.get(k) : null),
    setItem: (k, v) => map.set(k, String(v)),
    removeItem: (k) => map.delete(k),
    map,
  };
};

test("the old single note becomes the first note", () => {
  const storage = memory({ "misstype-editor-md": "# 購物清單\n\n牛奶" });
  const notes = createNotes(storage);
  const index = notes.load();
  assert.equal(index.notes.length, 1);
  assert.equal(index.notes[0].title, "購物清單");
  assert.equal(notes.read(index.current), "# 購物清單\n\n牛奶");
  assert.equal(storage.getItem("misstype-editor-md"), null);
  // Loading again does not migrate twice.
  assert.equal(createNotes(storage).load().notes.length, 1);
});

test("a first visit starts with one empty note", () => {
  const notes = createNotes(memory());
  const index = notes.load();
  assert.equal(index.notes.length, 1);
  assert.equal(notes.read(index.current), "");
});

test("titles come from the first line without Markdown markers", () => {
  assert.equal(titleOf("## 標題"), "標題");
  assert.equal(titleOf("&nbsp;\n\n* **重點** 事項"), "重點 事項");
  assert.equal(titleOf("> 引用"), "引用");
  assert.equal(titleOf("1. 第一步"), "第一步");
  assert.equal(titleOf(""), "");
  assert.equal(titleOf("字".repeat(80)).length, 61);
});

test("writing a note reports a title change", () => {
  const notes = createNotes(memory());
  const id = notes.load().current;
  assert.equal(notes.write(id, "你好"), true);
  assert.equal(notes.write(id, "你好\n\n更多"), false);
  assert.equal(notes.load().notes[0].title, "你好");
});

test("new notes go to the top of their folder and open", () => {
  const notes = createNotes(memory());
  const folder = notes.createFolder("Projects");
  const first = notes.load().current;
  const a = notes.create(folder);
  const b = notes.create(folder, "# 匯入的");
  const index = notes.load();
  assert.equal(index.current, b);
  assert.deepEqual(index.notes.map((n) => n.id), [b, a, first]);
  assert.equal(index.notes[0].title, "匯入的");
  assert.equal(notes.create("no-such-folder") && notes.load().notes[0].folder, null);
});

test("moving a note between folders and before another note", () => {
  const notes = createNotes(memory());
  const p = notes.createFolder("Projects");
  const a = notes.create(p);
  const b = notes.create(p);
  const loose = notes.create(null);
  notes.move(loose, p, a);
  assert.deepEqual(notes.load().notes.filter((n) => n.folder === p).map((n) => n.id), [b, loose, a]);
  notes.move(b, null);
  assert.equal(notes.load().notes.find((n) => n.id === b).folder, null);
});

test("deleting the open note opens a neighbour, deleting the last makes a new one", () => {
  const notes = createNotes(memory());
  const only = notes.load().current;
  const next = notes.delete(only);
  assert.notEqual(next, only);
  assert.equal(notes.load().notes.length, 1);
  const f = notes.createFolder("Areas");
  const a = notes.create(f);
  const b = notes.create(f);
  assert.equal(notes.delete(b), a);
});

test("deleting a folder keeps its notes at the top level", () => {
  const notes = createNotes(memory());
  const f = notes.createFolder("Resources");
  const a = notes.create(f);
  notes.deleteFolder(f);
  const index = notes.load();
  assert.equal(index.folders.length, 0);
  assert.equal(index.notes.find((n) => n.id === a).folder, null);
});

test("PARA folders are added once", () => {
  const notes = createNotes(memory());
  notes.createFolder("projects");
  assert.equal(notes.addPara(), 3);
  assert.equal(notes.addPara(), 0);
  assert.deepEqual(notes.load().folders.map((f) => f.name), ["projects", "Areas", "Resources", "Archives"]);
});

test("a damaged index starts over instead of throwing", () => {
  const notes = createNotes(memory({ "misstype-editor-notes": "{not json" }));
  assert.equal(notes.load().notes.length, 1);
});
