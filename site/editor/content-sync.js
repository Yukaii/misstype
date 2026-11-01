// Remote side of the per-note content CRDT. A note has one immutable seed and
// one state file per device:
//
//   notes/<id>.seed.json        { v: 1, state }   written once, create-only
//   notes/<id>.<device>.json    { v: 1, device, state }
//
// The seed is what makes merging possible at all: a Y.Doc seeded from the same
// update on two devices shares item ids, so later edits merge. A device that
// edited before it saw the seed has an independent history; that note falls
// back to the old "keep both texts" copy for one pass (see sync.js), which then
// rebases the kept text onto the seed. Once linked, later passes merge.
import * as Y from "yjs";
import { b64ToBytes } from "./binary.js";
import { hashOf } from "./hash.js";

export const isContentFile = (name) => /^notes\/[^.]+\.(?:seed|[^.]+)\.json$/i.test(name);
export const seedFile = (id) => `notes/${id}.seed.json`;
export const stateFile = (id, device) => `notes/${id}.${device}.json`;

const SEED = /^notes\/([^.]+)\.seed\.json$/i;
const STATE = /^notes\/([^.]+)\.([^.]+)\.json$/i;

const vectorOf = (seed, states) => {
  const updates = [b64ToBytes(seed), ...states.map((s) => b64ToBytes(s.state))];
  const merged = updates.length === 1 ? updates[0] : Y.mergeUpdates(updates);
  return Y.encodeStateVectorFromUpdate(merged);
};

/**
 * One content pass, before the Markdown body loop. Returns:
 *   merged     id -> Markdown that includes remote edits
 *   linked     ids whose document shares the remote seed (safe to merge)
 *   applied    ids where this pass actually applied remote content
 *   blocked    id -> { seed, states } for an unlinked local document; sync.js
 *              keeps both texts and rebases the local one after the copy
 *   replaced   ids whose Y.Doc object was replaced (the editor must rebuild a
 *              cached state bound to the old one)
 */
export async function syncContent({ content, store, remote, files, busy, local, bodyIds, device, bodyChanged = () => false }) {
  const seeds = new Map();
  const states = new Map();
  for (const [name, file] of files) {
    const s = SEED.exec(name);
    if (s) { seeds.set(s[1], { name, rev: file.rev }); continue; }
    const t = STATE.exec(name);
    if (t) {
      const list = states.get(t[1]) ?? [];
      list.push({ name, rev: file.rev });
      states.set(t[1], list);
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
  const blocked = new Map();

  const remember = (id, markdown) => {
    const note = store.load().notes.find((n) => n.id === id);
    if (!note) { merged.set(id, markdown); return; }
    if (store.read(id) === markdown) return;
    merged.set(id, markdown);
    store.write(id, markdown);
  };

  for (const id of ids) {
    const note = local.get(id);
    const hasBody = bodyIds.has(id);
    if (!note && !hasBody) continue;
    if (busy(id)) continue;
    const hasLocal = content.has(id);
    let seed = seeds.get(id);

    if (!seed) {
      if (!hasLocal) continue;
      const markdown = content.markdown(id);
      if (!markdown.trim() && !hasBody) continue;
      const state = content.state(id);
      try {
        const rev = await remote.write(seedFile(id), JSON.stringify({ v: 1, state }), null);
        seed = { name: seedFile(id), rev };
        content.markLinked(id, hashOf(state));
        linked.add(id);
      } catch (err) {
        if (!err?.conflict) throw err;
        // Another device seeded between list() and write(): refresh and use it.
        for (const f of await remote.list()) files.set(f.name, f);
        const found = [...files.keys()].find((name) => SEED.test(name) && SEED.exec(name)[1] === id);
        if (!found) continue;
        seed = { name: found, rev: files.get(found).rev };
      }
    }

    let seedText;
    try { seedText = JSON.parse(await remote.read(seed.name) || ""); } catch { continue; }
    if (seedText?.v !== 1 || typeof seedText.state !== "string") continue;
    const seedId = hashOf(seedText.state);
    const updates = [];
    for (const file of states.get(id) ?? []) {
      try {
        const parsed = JSON.parse(await remote.read(file.name) || "");
        if (parsed?.v === 1 && typeof parsed.state === "string") updates.push({ ...file, state: parsed.state });
      } catch { /* damaged state: the author still has it */ }
    }
    const seedMarkdown = content.preview(seedText.state);
    const localMarkdown = hasLocal
      ? content.markdown(id)
      : (note ? content.normalize(store.read(id)) : "");

    if (hasLocal) {
      const sameSeed = content.linked(id) && content.seedOf(id) === seedId;
      if (sameSeed) {
        for (const update of updates) if (content.apply(id, update.state).changed) applied.add(id);
        const markdown = content.markdown(id);
        linked.add(id);
        remember(id, markdown);
      } else if (content.pristine(id) && (localMarkdown === seedMarkdown || !bodyChanged(id))) {
        content.adopt(id, seedText.state, updates.map((u) => u.state));
        linked.add(id);
        applied.add(id);
        replaced.add(id);
        remember(id, content.markdown(id));
      } else {
        blocked.set(id, { seed: seedText.state, states: updates.map((u) => u.state) });
        continue;
      }
    } else {
      // No local document yet. If the note has local body edits (not just an
      // older base) that differ from the seed, it predates the seed; keep it as
      // an independent doc. An unchanged old body simply adopts the seed.
      if (note && bodyChanged(id) && localMarkdown !== seedMarkdown) {
        content.open(id);
        blocked.set(id, { seed: seedText.state, states: updates.map((u) => u.state) });
        continue;
      }
      content.adopt(id, seedText.state, updates.map((u) => u.state));
      linked.add(id);
      applied.add(id);
      replaced.add(id);
      remember(id, content.markdown(id));
    }

    // Push this device's own edits. The seed and every state file we read are
    // the remote history; only what is missing there needs a new file.
    const name = stateFile(id, device);
    const existing = files.get(name);
    const delta = Y.encodeStateAsUpdate(content.doc(id), vectorOf(seedText.state, updates));
    // No local edits beyond the seed/states: the seed is enough.
    if (delta.length <= 2) continue;
    try {
      await remote.write(name, JSON.stringify({ v: 1, device, state: content.state(id) }), existing?.rev ?? null);
      uploaded.add(id);
    } catch (err) {
      if (!err?.conflict) throw err;
      // Another tab wrote our file first; it carries the same shared history.
    }
  }

  return { merged, linked, applied, replaced, uploaded, blocked };
}
