// Per-note document CRDT. A Y.Doc owns the ProseMirror document for one note;
// y-prosemirror keeps the editor and the Y.Doc in step. The Markdown cache in
// notes.js stays the export (`.md`, copy, download) and the body-file sync
// marker, but the Y.Doc is what merges concurrent edits.
//
// Local state is three JSON records per note:
//
//   misstype-editor-crdt:<id>       { v: 2, state, vector, linked, seed, base }
//   misstype-editor-crdt-tail:<id>  { v: 1, tail }
//   misstype-editor-crdt-up:<id>    { uploaded, seq, epoch, dirty }
//
// `state` is the last full encoding; `tail` holds the edits since then, in its
// own key, so a save writes only the pending tail instead of re-encoding and
// rewriting the whole history (the full state is rewritten only when the tail
// grows past `state` or FOLD_BYTES). Version 1 records (state only) still load.
// `up` is what sync needs: the vector already uploaded, the last chunk number,
// the seed epoch, and whether a local edit is waiting.
//
// `linked` means this document's history goes back to a canonical seed (the
// note's `notes/<id>.seed.json`, or a checkpoint `notes/<id>.seed.<n>.json`).
// Two devices that independently initialize a
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
const TAIL_KEY = (id) => `misstype-editor-crdt-tail:${id}`;
/** What this device has already uploaded, kept apart so a pass does not rewrite the big record. */
const UP_KEY = (id) => `misstype-editor-crdt-up:${id}`;
const FRAGMENT = "content";
/** Fold the pending tail into a full state once it is this big, or bigger than the state itself. */
const FOLD_BYTES = 8 * 1024;

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
  const uploads = new Map();

  /** { uploaded: base64 state vector | null, seq: last chunk number } */
  function uploadState(id) {
    if (uploads.has(id)) return uploads.get(id);
    let value = { uploaded: null, seq: 0, epoch: 0, dirty: false };
    const raw = read(storage, UP_KEY(id));
    if (raw) {
      try {
        const parsed = JSON.parse(raw);
        value = {
          uploaded: typeof parsed.uploaded === "string" ? parsed.uploaded : null,
          seq: Number.isFinite(parsed.seq) ? parsed.seq : 0,
          epoch: Number.isFinite(parsed.epoch) ? parsed.epoch : 0,
          dirty: Boolean(parsed.dirty),
        };
      } catch { /* damaged: upload everything again */ }
    }
    uploads.set(id, value);
    return value;
  }

  function setUploaded(id, uploaded, seq, epoch = uploadState(id).epoch) {
    const value = { uploaded, seq, epoch, dirty: uploadState(id).dirty };
    uploads.set(id, value);
    write(storage, UP_KEY(id), JSON.stringify(value));
  }

  function setEpoch(id, epoch) {
    const value = uploadState(id);
    setUploaded(id, value.uploaded, value.seq, epoch);
  }

  function setDirty(id, dirty) {
    const value = uploadState(id);
    if (value.dirty === dirty) return;
    value.dirty = dirty;
    write(storage, UP_KEY(id), JSON.stringify(value));
  }

  /** Local updates mark the note for upload; remote ones must not. */
  function observe(record) {
    record.observer = () => {
      if (!record.remote) record.dirty = true;
      onUpdate(record.id);
    };
    record.doc.on("update", record.observer);
  }

  function make(id, markdown) {
    const doc = new Y.Doc();
    const fragment = doc.getXmlFragment(FRAGMENT);
    prosemirrorToYXmlFragment(parseMarkdown(markdown), fragment);
    const record = {
      id,
      doc,
      fragment,
      dirty: false,
      // The serialized form, not the input Markdown: CommonMark round-trips can
      // normalize markers, and a normative difference must not look like an edit.
      meta: { linked: false, seed: null, base: hashOf(toMarkdown(yXmlFragmentToProseMirrorRootNode(fragment, schema))) },
    };
    observe(record);
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
    if ((parsed?.v !== 1 && parsed?.v !== 2) || typeof parsed.state !== "string") return make(id, notes.read(id));
    const doc = new Y.Doc();
    let tail = null;
    try {
      Y.applyUpdate(doc, b64ToBytes(parsed.state));
      // The tail lives in its own key so a save writes only the delta. Records
      // from before that split may carry it inline.
      const rawTail = read(storage, TAIL_KEY(id));
      let text = parsed.v === 2 && typeof parsed.tail === "string" ? parsed.tail : null;
      if (rawTail) {
        try {
          const parsedTail = JSON.parse(rawTail);
          if (parsedTail?.v === 1 && typeof parsedTail.tail === "string") text = parsedTail.tail;
        } catch { /* damaged tail: the full state still loads */ }
      }
      if (text) {
        Y.applyUpdate(doc, b64ToBytes(text));
        tail = text;
      }
    } catch { return make(id, notes.read(id)); }
    const fragment = doc.getXmlFragment(FRAGMENT);
    if (fragment.length === 0) return make(id, notes.read(id));
    const up = uploadState(id);
    const record = {
      id,
      doc,
      fragment,
      // A linked note with no upload marker comes from before this bookkeeping:
      // upload it once rather than assume the remote already has it.
      dirty: up.dirty || (!up.uploaded && Boolean(parsed.linked)),
      meta: {
        linked: Boolean(parsed.linked),
        seed: typeof parsed.seed === "string" ? parsed.seed : null,
        base: typeof parsed.base === "string" ? parsed.base : hashOf(notes.read(id)),
      },
      // What is already stored, and the state vector it covers: the next save
      // encodes only what happened since.
      stored: { state: parsed.state, tail },
      vector: Y.encodeStateVector(doc),
    };
    observe(record);
    records.set(id, record);
    return record;
  }

  /** Rewrites the full-state key; the tail key is left alone. */
  function saveState(id, record, state, vector) {
    write(storage, KEY(id), JSON.stringify({
      v: 2,
      state,
      vector: bytesToB64(vector),
      linked: record.meta.linked,
      seed: record.meta.seed,
      base: record.meta.base,
    }));
    record.vector = vector;
  }

  function saveFull(id, record, state, vector) {
    saveState(id, record, state, vector);
    try { storage.removeItem(TAIL_KEY(id)); } catch { /* private mode */ }
    record.stored = { state, tail: null };
  }

  function saveTail(id, record, tail, vector) {
    write(storage, TAIL_KEY(id), JSON.stringify({ v: 1, tail }));
    record.stored = { state: record.stored.state, tail };
    record.vector = vector;
  }

  /**
   * Writes what changed since the last save. The first save (or a fold) writes
   * the full state; later saves rewrite only the pending tail (bounded by
   * FOLD_BYTES), so typing does not re-encode the note's whole history on the
   * main thread and the per-save write does not grow with it.
   */
  function persist(id) {
    const record = records.get(id);
    if (!record) return;
    setDirty(id, record.dirty);
    const vector = Y.encodeStateVector(record.doc);
    const stored = record.stored;
    if (!stored) {
      saveFull(id, record, bytesToB64(Y.encodeStateAsUpdate(record.doc)), vector);
      return;
    }
    const delta = Y.encodeStateAsUpdate(record.doc, record.vector);
    if (delta.length <= 2) {
      // Only metadata changed (linked/seed/base): rewrite the state key.
      saveState(id, record, stored.state, vector);
      return;
    }
    const tail = stored.tail ? Y.mergeUpdates([b64ToBytes(stored.tail), delta]) : delta;
    // Fold once the tail is big, or once keeping it costs more than a full write.
    if (tail.length > FOLD_BYTES || tail.length > b64ToBytes(stored.state).length) {
      saveFull(id, record, bytesToB64(Y.encodeStateAsUpdate(record.doc)), vector);
    } else {
      saveTail(id, record, bytesToB64(tail), vector);
    }
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

  /** A fresh history for `markdown`, for a checkpoint that drops old tombstones. */
  function freshState(markdown) {
    const doc = new Y.Doc();
    prosemirrorToYXmlFragment(parseMarkdown(markdown), doc.getXmlFragment(FRAGMENT));
    const state = bytesToB64(Y.encodeStateAsUpdate(doc));
    doc.destroy();
    return state;
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
      // Adopting is not a local edit: the remote already has this state.
      dirty: false,
      meta: { linked: true, seed: hashOf(seedState), base: hashOf(seedMarkdown) },
    };
    observe(record);
    records.set(id, record);
    persist(id);
    return seedMarkdown;
  }

  function apply(id, update) {
    const record = load(id);
    const beforeVector = Y.encodeStateVector(record.doc);
    // A delete-only update leaves the state vector unchanged, so compare the
    // text too; otherwise the other device would never rebuild the note.
    const before = markdownOf(record);
    record.remote = true;
    try { Y.applyUpdate(record.doc, b64ToBytes(update)); } finally { record.remote = false; }
    const markdown = markdownOf(record);
    const changed = markdown !== before || !sameVector(beforeVector, Y.encodeStateVector(record.doc));
    if (changed) persist(id);
    return { changed, markdown: changed ? markdown : null };
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
    try { storage.removeItem(TAIL_KEY(id)); } catch { /* private mode */ }
    try { storage.removeItem(UP_KEY(id)); } catch { /* private mode */ }
    uploads.delete(id);
  }

  return {
    open: load,
    has: (id) => records.has(id) || Boolean(read(storage, KEY(id))),
    doc: (id) => load(id).doc,
    vector: (id) => bytesToB64(Y.encodeStateVector(load(id).doc)),
    markdown,
    normalize,
    state,
    freshState,
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
    /** What this device has uploaded for a note: a state vector (or null) and the last chunk. */
    uploaded: (id) => uploadState(id).uploaded,
    seq: (id) => uploadState(id).seq,
    epoch: (id) => uploadState(id).epoch,
    setUploaded,
    setEpoch,
    /** Local edits since the last successful upload. */
    dirty: (id) => { const record = records.get(id); return record ? record.dirty : uploadState(id).dirty; },
    clearDirty: (id) => { const record = records.get(id); if (record) record.dirty = false; setDirty(id, false); },
    setDirty,
    /** For tests: the raw local record. */
    raw: (id) => read(storage, KEY(id)),
  };
}
