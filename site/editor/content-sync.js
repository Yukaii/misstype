// Remote side of the per-note content CRDT. A note has one immutable seed per
// epoch and one state chunk per device:
//
//   notes/<id>.seed.json          { v: 1, state }        epoch 0 (older clients)
//   notes/<id>.seed.<n>.json      { v: 1, epoch, state } a checkpoint
//   notes/<id>.<device>-<seq>.json          { v: 1, device, seq, state }
//   notes/<id>.<device>-<seq>.<n>.json      the same, in epoch n
//
// The seed is what makes merging possible at all: a Y.Doc seeded from the same
// update on two devices shares item ids, so later edits merge. A device that
// edited before it saw the seed has an independent history; that note falls
// back to the old "keep both texts" copy for one pass (see sync.js), which then
// rebases the kept text onto the seed. Once linked, later passes merge.
//
// A checkpoint re-seeds a note from its merged Markdown when the history has
// grown well past the text (tombstones never leave a Yjs document). It writes a
// new seed epoch and removes the older chunks; a device that had no local edits
// adopts it without a duplicate, one with edits falls back to the copy above.
// Epoch 0 is kept for older clients, which ignore the new seed and chunks.
//
// A pass should not re-read history it already applied. `seen` (kept in the
// sync base) remembers each content file's revision, bytes and state vector, so
// an unchanged file is skipped when the local document already contains its
// vector. The vectors are also unioned to tell whether this device has
// anything the remote does not, without merging the whole history.
import * as Y from "yjs";
import { b64ToBytes, bytesToB64 } from "./binary.js";
import { hashOf } from "./hash.js";

export const isContentFile = (name) => /^notes\/[^.]+\.(?:seed(?:\.\d+)?|[^.]+(?:-\d+)?(?:\.\d+)?)\.json$/i.test(name);
export const seedFile = (id, epoch = 0) => (epoch ? `notes/${id}.seed.${epoch}.json` : `notes/${id}.seed.json`);
/** The pre-chunk layout, still read and still written by older clients. */
export const stateFile = (id, device) => `notes/${id}.${device}.json`;
/** One append-only delta for a device; `v: 1` so older clients read epoch 0. */
export const chunkFile = (id, device, seq, epoch = 0) => (epoch
  ? `notes/${id}.${device}-${seq}.${epoch}.json`
  : `notes/${id}.${device}-${seq}.json`);

const SEED = /^notes\/([^.]+)\.seed(?:\.(\d+))?\.json$/i;
const CHUNK = /^notes\/([^.]+)\.([^.]+?)-(\d+)(?:\.(\d+))?\.json$/i;
const LEGACY = /^notes\/([^.]+)\.([^.]+)\.json$/i;
/** Rewrite a device's chunks as one full state this often (bounded file count). */
const COMPACT_EVERY = 32;
/** Checkpoint once the history is this many times the text, but never below this. */
const CHECKPOINT_RATIO = 8;
const CHECKPOINT_MIN = 16 * 1024;

const ownFile = (name, id, device) => name === stateFile(id, device) || name.startsWith(`notes/${id}.${device}-`);

const decodeVector = (b64) => Y.decodeStateVector(b64ToBytes(b64));
// A chunk is a delta, and encodeStateVectorFromUpdate only counts structs that
// start at clock 0 (it returns an empty vector for "8 -> 16"). parseUpdateMeta
// gives the end clock of the update, which is what the next pass needs.
const vectorOfUpdate = (state) => bytesToB64(Y.encodeStateVector(Y.parseUpdateMeta(b64ToBytes(state)).to));

/** The union of state vectors, as base64: what the remote history covers. */
function unionVectors(vectors) {
  const out = new Map();
  for (const vector of vectors) {
    if (!vector) continue;
    for (const [client, clock] of decodeVector(vector)) out.set(client, Math.max(out.get(client) ?? 0, clock));
  }
  return bytesToB64(Y.encodeStateVector(out));
}

/** Every struct in `remote` is already in `local`. */
function containsVector(local, remote) {
  const have = decodeVector(local);
  for (const [client, clock] of decodeVector(remote)) {
    if ((have.get(client) ?? 0) < clock) return false;
  }
  return true;
}

/**
 * Appends this device's edits as a chunk (a Yjs update since its last chunk),
 * so an edit uploads the edit, not the note's whole history. Every
 * COMPACT_EVERY chunks, or on `reset`, it writes one full state and removes
 * the older chunks this device owns. Older clients read an epoch-0 chunk as an
 * ordinary state file, so they keep merging.
 */
export async function writeContentChunk({ content, remote, files, seen, id, device, reset = false }) {
  if (!reset && !content.dirty(id)) return null;
  const uploaded = reset ? null : content.uploaded(id);
  const delta = Y.encodeStateAsUpdate(content.doc(id), uploaded ? b64ToBytes(uploaded) : Y.encodeStateVector(new Map()));
  if (delta.length <= 2 && !reset) {
    content.clearDirty(id);
    return null;
  }
  const seq = content.seq(id) + 1;
  const epoch = content.epoch(id);
  const full = reset || seq % COMPACT_EVERY === 0;
  const name = chunkFile(id, device, seq, epoch);
  const state = full ? content.state(id) : bytesToB64(delta);
  const text = JSON.stringify({ v: 1, device, seq, epoch, state });
  const rev = await remote.write(name, text, null);
  files.set(name, { name, rev });
  if (seen) seen[name] = { rev, vector: content.vector(id), bytes: text.length };
  content.setUploaded(id, content.vector(id), seq, epoch);
  content.clearDirty(id);
  if (full) {
    for (const old of [...files.keys()]) {
      if (old === name || !ownFile(old, id, device)) continue;
      await remote.remove(old);
      files.delete(old);
      if (seen) delete seen[old];
    }
  }
  return { name, rev, seq, full };
}

/**
 * One content pass, before the Markdown body loop. Returns:
 *   merged      id -> Markdown that includes remote edits
 *   linked      ids whose document shares the remote seed (safe to merge)
 *   applied     ids where this pass actually applied remote content
 *   blocked     id -> { seed, states } for an unlinked local document; sync.js
 *               keeps both texts and rebases the local one after the copy
 *   replaced    ids whose Y.Doc object was replaced (the editor must rebuild a
 *               cached state bound to the old one)
 *   checkpointed ids whose history was folded into a new seed
 *   seen        name -> { rev, hash?, vector, bytes } for the next pass
 */
export async function syncContent({ content, store, remote, files, busy, local, bodyIds, device, bodyChanged = () => false, seen = {}, checkpointBytes = null }) {
  const seeds = new Map();
  const states = new Map();
  for (const [name, file] of files) {
    const s = SEED.exec(name);
    if (s) {
      const id = s[1];
      const epoch = Number(s[2] ?? 0);
      const current = seeds.get(id);
      if (!current || epoch > current.epoch) seeds.set(id, { name, rev: file.rev, epoch });
      continue;
    }
    const c = CHUNK.exec(name);
    if (c) {
      const list = states.get(c[1]) ?? [];
      list.push({ name, rev: file.rev, device: c[2], seq: Number(c[3]), epoch: Number(c[4] ?? 0) });
      states.set(c[1], list);
      continue;
    }
    const l = LEGACY.exec(name);
    if (l && l[2] !== "seed") {
      const list = states.get(l[1]) ?? [];
      list.push({ name, rev: file.rev, device: l[2], seq: 0, epoch: 0 });
      states.set(l[1], list);
    }
  }

  const ids = new Set();
  for (const id of local.keys()) if (content.has(id)) ids.add(id);
  for (const id of seeds.keys()) if (local.has(id) || bodyIds.has(id)) ids.add(id);
  for (const id of states.keys()) if (local.has(id) || bodyIds.has(id)) ids.add(id);

  const merged = new Map();
  const linked = new Set();
  const applied = new Set();
  const replaced = new Set();
  const uploaded = new Set();
  const checkpointed = new Set();
  const blocked = new Map();
  const nextSeen = { ...seen };

  const remember = (id, markdown) => {
    const note = store.load().notes.find((n) => n.id === id);
    if (!note) { merged.set(id, markdown); return; }
    if (store.read(id) === markdown) return;
    merged.set(id, markdown);
    store.write(id, markdown);
  };

  /** A new seed from the merged text, then drop the history it replaces. */
  const checkpoint = async (id, epoch, markdown) => {
    const state = content.freshState(markdown);
    const next = epoch + 1;
    const name = seedFile(id, next);
    const text = JSON.stringify({ v: 1, epoch: next, state, created: Date.now() });
    let rev;
    try {
      rev = await remote.write(name, text, null);
    } catch (err) {
      if (err?.conflict) return false; // another device checkpointed first
      throw err;
    }
    content.adopt(id, state, []);
    content.setEpoch(id, next);
    content.setUploaded(id, content.vector(id), 0, next);
    linked.add(id);
    applied.add(id);
    replaced.add(id);
    checkpointed.add(id);
    files.set(name, { name, rev });
    nextSeen[name] = { rev, hash: hashOf(state), vector: content.vector(id), bytes: text.length };
    for (const old of [...files.keys()]) {
      if (old === name || !isContentFile(old)) continue;
      if (old.slice("notes/".length).split(".")[0] !== id) continue;
      // Keep the epoch-0 seed: older clients still read it.
      if (old === seedFile(id, 0)) continue;
      await remote.remove(old);
      files.delete(old);
      delete nextSeen[old];
    }
    return true;
  };

  for (const id of ids) {
    const note = local.get(id);
    const hasBody = bodyIds.has(id);
    if (!note && !hasBody) continue;
    if (busy(id)) continue;
    const hasLocal = content.has(id);
    const localVector = hasLocal ? content.vector(id) : null;
    let seed = seeds.get(id);
    let epoch = seed?.epoch ?? 0;
    let seedId = null;
    let seedVector = null;
    let seedState = null;
    let seedBytes = 0;

    if (!seed) {
      if (!hasLocal) continue;
      const markdown = content.markdown(id);
      if (!markdown.trim() && !hasBody) continue;
      const state = content.state(id);
      const name = seedFile(id, 0);
      const text = JSON.stringify({ v: 1, state });
      try {
        const rev = await remote.write(name, text, null);
        seed = { name, rev, epoch: 0 };
        epoch = 0;
        seedId = hashOf(state);
        seedVector = content.vector(id);
        seedBytes = text.length;
        content.markLinked(id, seedId);
        content.setEpoch(id, 0);
        content.clearDirty(id);
        linked.add(id);
        files.set(seed.name, { name: seed.name, rev });
        nextSeen[seed.name] = { rev, hash: seedId, vector: seedVector, bytes: text.length };
      } catch (err) {
        if (!err?.conflict) throw err;
        // Another device seeded between list() and write(): refresh and use the
        // newest epoch it wrote.
        for (const f of await remote.list()) files.set(f.name, f);
        let found = null;
        for (const name of files.keys()) {
          const match = SEED.exec(name);
          if (!match || match[1] !== id) continue;
          const foundEpoch = Number(match[2] ?? 0);
          if (!found || foundEpoch > found.epoch) found = { name, rev: files.get(name).rev, epoch: foundEpoch };
        }
        if (!found) continue;
        seed = found;
        epoch = found.epoch;
      }
    }

    let sameSeed = false;
    if (seedId) {
      sameSeed = hasLocal && content.linked(id) && content.seedOf(id) === seedId;
      if (sameSeed) content.setEpoch(id, epoch);
    } else {
      const cached = seen[seed.name];
      // The seed is immutable and create-only, so an unchanged revision with a
      // known hash means the local document already goes back to it.
      if (hasLocal && cached?.rev === seed.rev && cached.hash && cached.vector
        && typeof cached.bytes === "number"
        && content.linked(id) && content.seedOf(id) === cached.hash) {
        seedId = cached.hash;
        seedVector = cached.vector;
        seedBytes = cached.bytes;
        sameSeed = true;
        nextSeen[seed.name] = cached;
        content.setEpoch(id, epoch);
      } else {
        let seedRaw;
        let seedText;
        try {
          seedRaw = await remote.read(seed.name) || "";
          seedText = JSON.parse(seedRaw);
        } catch { continue; }
        if (seedText?.v !== 1 || typeof seedText.state !== "string") continue;
        seedState = seedText.state;
        seedId = hashOf(seedState);
        seedVector = vectorOfUpdate(seedState);
        seedBytes = seedRaw.length;
        sameSeed = hasLocal && content.linked(id) && content.seedOf(id) === seedId;
        if (sameSeed) content.setEpoch(id, epoch);
        nextSeen[seed.name] = { rev: seed.rev, hash: seedId, vector: seedVector, bytes: seedBytes };
      }
    }

    // Only states of the current epoch are merged; older epochs are history a
    // checkpoint replaced. When the local history is independent (or missing)
    // every current state is needed to adopt or rebase it.
    const updates = [];
    const stateVectors = [];
    let stateBytes = 0;
    for (const file of states.get(id) ?? []) {
      if (file.epoch !== epoch) continue;
      const cached = seen[file.name];
      if (sameSeed && cached && cached.rev === file.rev && cached.vector && typeof cached.bytes === "number"
        && containsVector(localVector, cached.vector)) {
        stateVectors.push(cached.vector);
        stateBytes += cached.bytes;
        nextSeen[file.name] = cached;
        continue;
      }
      try {
        const text = await remote.read(file.name) || "";
        const parsed = JSON.parse(text);
        if ((parsed?.v !== 1 && parsed?.v !== 2) || typeof parsed.state !== "string") continue;
        const vector = vectorOfUpdate(parsed.state);
        stateVectors.push(vector);
        stateBytes += text.length;
        updates.push({ ...file, state: parsed.state });
        nextSeen[file.name] = { rev: file.rev, vector, bytes: text.length };
      } catch { /* damaged state: the author still has it */ }
    }

    const remoteVector = unionVectors([seedVector, ...stateVectors]);
    const localMarkdown = hasLocal
      ? content.markdown(id)
      : (note ? content.normalize(store.read(id)) : "");

    if (hasLocal) {
      if (sameSeed) {
        for (const update of updates) if (content.apply(id, update.state).changed) applied.add(id);
        const markdown = content.markdown(id);
        linked.add(id);
        remember(id, markdown);
      } else {
        // Adopting or rebasing needs the seed and every state, which were read
        // above because an unlinked history skips nothing.
        const seedMarkdown = content.preview(seedState, updates.map((u) => u.state));
        // A device on an older epoch whose body has not changed has no local
        // edits to preserve: it can adopt a checkpoint without the copy
        // fallback, even though its document text is behind the new seed.
        const untouched = content.pristine(id) || (content.linked(id) && !bodyChanged(id));
        if (untouched && (localMarkdown === seedMarkdown || !bodyChanged(id))) {
          content.adopt(id, seedState, updates.map((u) => u.state));
          content.setEpoch(id, epoch);
          linked.add(id);
          applied.add(id);
          replaced.add(id);
          remember(id, content.markdown(id));
        } else {
          blocked.set(id, { seed: seedState, states: updates.map((u) => u.state), epoch });
          continue;
        }
      }
    } else {
      // No local document yet. If the note has local body edits (not just an
      // older base) that differ from the seed, it predates the seed; keep it as
      // an independent doc. An unchanged old body simply adopts the seed.
      const seedMarkdown = content.preview(seedState, updates.map((u) => u.state));
      if (note && bodyChanged(id) && localMarkdown !== seedMarkdown) {
        content.open(id);
        blocked.set(id, { seed: seedState, states: updates.map((u) => u.state), epoch });
        continue;
      }
      content.adopt(id, seedState, updates.map((u) => u.state));
      content.setEpoch(id, epoch);
      linked.add(id);
      applied.add(id);
      replaced.add(id);
      remember(id, content.markdown(id));
    }

    // Push this device's own edits. The remote vector is the union of the seed
    // and every state file; marking it uploaded first means the chunk below
    // carries only this device's edits, not the history it just read.
    content.setUploaded(id, remoteVector, content.seq(id), epoch);
    let written = null;
    try {
      written = await writeContentChunk({ content, remote, files, seen: nextSeen, id, device });
      if (written) uploaded.add(id);
    } catch (err) {
      if (!err?.conflict) throw err;
      // Another tab wrote the same chunk number first; next pass retries.
    }

    // A fully merged, idle note whose history dwarfs its text gets a new seed.
    if (!written && !busy(id) && sameSeed) {
      const markdown = content.markdown(id);
      const textBytes = new TextEncoder().encode(markdown).length;
      const limit = checkpointBytes ?? Math.max(CHECKPOINT_RATIO * textBytes, CHECKPOINT_MIN);
      if (seedBytes + stateBytes > limit) {
        await checkpoint(id, epoch, markdown);
      }
    }
  }

  // A note that was deleted, or a state file that disappeared, is not remembered.
  for (const name of Object.keys(nextSeen)) if (!files.has(name)) delete nextSeen[name];

  return { merged, linked, applied, replaced, uploaded, blocked, checkpointed, seen: nextSeen };
}
