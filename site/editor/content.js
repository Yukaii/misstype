// Per-note document CRDT. A Y.Doc owns the ProseMirror document for one note;
// y-prosemirror keeps the editor and the Y.Doc in step. The Markdown cache in
// notes.js stays the export (`.md`, copy, download) and the body-file sync
// marker, but the Y.Doc is what merges concurrent edits.
//
// Local state is one JSON record per note:
//
//   { v: 1, state: base64(update), linked, seed, base }
//
// `linked` means this document's history goes back to a canonical seed (the
// note's `notes/<id>.seed.json`). Two devices that independently initialize a
// Y.Doc from the same Markdown have different item histories and would
// concatenate instead of merge, so `linked` is what sync.js checks before it
// lets two histories meet. `base` is the hash of the Markdown when the local
// seed was made, used to tell an untouched (safe to replace with the remote
// seed) document from one with local edits (fall back to the old conflict
// copy for that one pass).
import * as Y from "yjs";
import { initProseMirrorDoc, prosemirrorToYXmlFragment, updateYFragment, yXmlFragmentToProseMirrorRootNode } from "y-prosemirror";
import { parseMarkdown, schema, toMarkdown } from "./model.js";
import { bytesToB64, b64ToBytes } from "./binary.js";
import { hashOf } from "./hash.js";

const KEY = (id) => `misstype-editor-crdt:${id}`;
const FRAGMENT = "content";

const read = (storage, key) => {
  try { return storage.getItem(key); } catch { return null; }
};
const write = (storage, key, value) => {
  try { storage.setItem(key, value); } catch { /* storage full or private mode */ }
};

/**
 * `notes` is the local Markdown store: a note with no CRDT record is seeded
 * from `notes.read(id)`. `onUpdate(id)` hears local and remote Y.Doc changes.
 */
export function createContent({ notes, storage = globalThis.localStorage, onUpdate = () => {} } = {}) {
  const records = new Map();

  function make(id, markdown) {
    const doc = new Y.Doc();
    const fragment = doc.getXmlFragment(FRAGMENT);
    prosemirrorToYXmlFragment(parseMarkdown(markdown), fragment);
    const record = {
      id,
      doc,
      fragment,
      // The serialized form, not the input Markdown: CommonMark round-trips can
      // normalize markers, and a normative difference must not look like an edit.
      meta: { linked: false, seed: null, base: hashOf(toMarkdown(yXmlFragmentToProseMirrorRootNode(fragment, schema))) },
    };
    record.observer = () => onUpdate(id);
    doc.on("update", record.observer);
    records.set(id, record);
    persist(id);
    return record;
  }

  function load(id) {
    const cached = records.get(id);
    if (cached) return cached;
    const raw = read(storage, KEY(id));
    if (!raw) return make(id, notes.read(id));
    let parsed;
    try { parsed = JSON.parse(raw); } catch { return make(id, notes.read(id)); }
    if (parsed?.v !== 1 || typeof parsed.state !== "string") return make(id, notes.read(id));
    const doc = new Y.Doc();
    try { Y.applyUpdate(doc, b64ToBytes(parsed.state)); } catch { return make(id, notes.read(id)); }
    const fragment = doc.getXmlFragment(FRAGMENT);
    if (fragment.length === 0) return make(id, notes.read(id));
    const record = {
      id,
      doc,
      fragment,
      meta: {
        linked: Boolean(parsed.linked),
        seed: typeof parsed.seed === "string" ? parsed.seed : null,
        base: typeof parsed.base === "string" ? parsed.base : hashOf(notes.read(id)),
      },
    };
    record.observer = () => onUpdate(id);
    doc.on("update", record.observer);
    records.set(id, record);
    return record;
  }

  function persist(id) {
    const record = records.get(id);
    if (!record) return;
    write(storage, KEY(id), JSON.stringify({
      v: 1,
      state: bytesToB64(Y.encodeStateAsUpdate(record.doc)),
      linked: record.meta.linked,
      seed: record.meta.seed,
      base: record.meta.base,
    }));
  }

  function markdownOf(record) {
    return toMarkdown(yXmlFragmentToProseMirrorRootNode(record.fragment, schema));
  }

  const normalize = (markdown) => toMarkdown(parseMarkdown(markdown));

  function markdown(id) {
    return markdownOf(load(id));
  }

  function state(id) {
    return bytesToB64(Y.encodeStateAsUpdate(load(id).doc));
  }

  function linked(id) {
    return Boolean(records.get(id)?.meta.linked || readLinked(id));
  }

  function readLinked(id) {
    const raw = read(storage, KEY(id));
    if (!raw) return false;
    try { return Boolean(JSON.parse(raw).linked); } catch { return false; }
  }

  function seedOf(id) {
    const record = records.get(id);
    if (record) return record.meta.seed;
    const raw = read(storage, KEY(id));
    if (!raw) return null;
    try { return JSON.parse(raw).seed ?? null; } catch { return null; }
  }

  /** The document has not changed since its local seed was made. */
  function pristine(id) {
    const record = load(id);
    return !record.meta.linked && hashOf(markdownOf(record)) === record.meta.base;
  }

  function markLinked(id, seed) {
    const record = load(id);
    record.meta.linked = true;
    record.meta.seed = seed;
    record.meta.base = hashOf(markdownOf(record));
    persist(id);
  }

  /**
   * Replaces the local document with a canonical seed plus the device states.
   * Returns the merged Markdown; the caller must discard any cached
   * EditorState for this note (and rebuild it if it is on screen).
   */
  function adopt(id, seedState, states = []) {
    const old = records.get(id);
    if (old) old.doc.off("update", old.observer);
    const doc = new Y.Doc();
    Y.applyUpdate(doc, b64ToBytes(seedState));
    for (const update of states) Y.applyUpdate(doc, b64ToBytes(update));
    const fragment = doc.getXmlFragment(FRAGMENT);
    const seedMarkdown = toMarkdown(yXmlFragmentToProseMirrorRootNode(fragment, schema));
    const record = {
      id,
      doc,
      fragment,
      meta: { linked: true, seed: hashOf(seedState), base: hashOf(seedMarkdown) },
    };
    record.observer = () => onUpdate(id);
    doc.on("update", record.observer);
    records.set(id, record);
    persist(id);
    return seedMarkdown;
  }

  function apply(id, update) {
    const record = load(id);
    const before = Y.encodeStateVector(record.doc);
    Y.applyUpdate(record.doc, b64ToBytes(update));
    const changed = !sameVector(before, Y.encodeStateVector(record.doc));
    if (changed) persist(id);
    return { changed, markdown: changed ? markdownOf(record) : null };
  }

  function sameVector(a, b) {
    if (a.length !== b.length) return false;
    for (let i = 0; i < a.length; i++) if (a[i] !== b[i]) return false;
    return true;
  }

  /** Markdown of a seed alone or a seed plus device states, without touching local state. */
  function preview(seedState, states = []) {
    const doc = new Y.Doc();
    Y.applyUpdate(doc, b64ToBytes(seedState));
    for (const update of states) Y.applyUpdate(doc, b64ToBytes(update));
    const fragment = doc.getXmlFragment(FRAGMENT);
    const markdown = toMarkdown(yXmlFragmentToProseMirrorRootNode(fragment, schema));
    doc.destroy();
    return markdown;
  }

  /** Rebase an unlinked local document onto a remote seed, keeping the local text. */
  function rebase(id, seedState, states, markdown) {
    adopt(id, seedState, states);
    replaceMarkdown(id, markdown);
    return markdownOf(load(id));
  }

  /** For migration and tests: replace the document with Markdown in one CRDT update. */
  function replaceMarkdown(id, markdown) {
    const record = load(id);
    const { meta } = initProseMirrorDoc(record.fragment, schema);
    updateYFragment(record.doc, record.fragment, parseMarkdown(markdown), meta);
    persist(id);
    return markdownOf(record);
  }

  function forget(id) {
    const record = records.get(id);
    if (record) {
      record.doc.off("update", record.observer);
      record.doc.destroy();
      records.delete(id);
    }
    try { storage.removeItem(KEY(id)); } catch { /* private mode */ }
  }

  return {
    open: load,
    has: (id) => records.has(id) || Boolean(read(storage, KEY(id))),
    doc: (id) => load(id).doc,
    vector: (id) => bytesToB64(Y.encodeStateVector(load(id).doc)),
    markdown,
    normalize,
    state,
    preview,
    rebase,
    linked,
    seedOf,
    pristine,
    markLinked,
    adopt,
    apply,
    persist,
    replaceMarkdown,
    forget,
    /** For tests: the raw local record. */
    raw: (id) => read(storage, KEY(id)),
  };
}
