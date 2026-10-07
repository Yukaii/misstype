// Drives the real decoder (site/public/misstype.wasm, copied into
// public/decoder by scripts/prepare-assets.mjs) through each beat's keys and
// records what the playground would draw after every key. This runs once, in
// calculateMetadata; render workers only receive the recorded snapshots.
import { WASI } from "@bjorn3/browser_wasi_shim";
import { staticFile } from "remotion";
import { keyFor } from "./keymap";
import { FPS, type TimedBeat } from "./timeline";

export type Snapshot = {
  committed: string;
  preedit: string;
  segments: [number, number][];
  focus: [number, number] | null;
  caret: number;
  candidates: string[];
  selected: number;
  selectionKeys: string[];
  keysActive: boolean;
};

export const EMPTY: Snapshot = {
  committed: "", preedit: "", segments: [], focus: null, caret: 0,
  candidates: [], selected: -1, selectionKeys: [], keysActive: false,
};

// handle_key takes a wall-clock time; give it the video's own clock so
// anything time-dependent in the session replays identically.
const EPOCH = 1_800_000_000;

type Exports = Record<string, (...args: number[]) => number> & { memory: WebAssembly.Memory };

async function load(): Promise<Exports> {
  const get = async (name: string) => {
    const res = await fetch(staticFile(`decoder/${name}`));
    if (!res.ok) throw new Error(`decoder/${name}: HTTP ${res.status} (run npm run prepare-assets)`);
    return res;
  };
  const [wasm, lexicon, toneless] = await Promise.all(
    ["misstype.wasm", "lexicon.tsv", "toneless.tsv"].map(get),
  );
  const wasi = new WASI([], [], []);
  const { instance } = await WebAssembly.instantiate(await wasm.arrayBuffer(), {
    wasi_snapshot_preview1: wasi.wasiImport,
  });
  wasi.start(instance as Parameters<typeof wasi.start>[0]);
  const ex = instance.exports as unknown as Exports;

  const lex = write(ex, await lexicon.text());
  const tone = write(ex, await toneless.text());
  const ok = ex.misstype_wasm_init(lex.ptr, lex.len, tone.ptr, tone.len);
  ex.misstype_wasm_free(lex.ptr);
  ex.misstype_wasm_free(tone.ptr);
  if (ok !== 1) throw new Error("misstype_wasm_init failed");
  return ex;
}

function write(ex: Exports, s: string) {
  const bytes = new TextEncoder().encode(s);
  const ptr = ex.misstype_wasm_alloc(bytes.length);
  new Uint8Array(ex.memory.buffer, ptr, bytes.length).set(bytes);
  return { ptr, len: bytes.length };
}

function readState(ex: Exports) {
  const ptr = ex.misstype_wasm_get_state_json();
  const u8 = new Uint8Array(ex.memory.buffer);
  let end = ptr;
  while (u8[end] !== 0) end++;
  return JSON.parse(new TextDecoder().decode(u8.subarray(ptr, end)));
}

// One snapshot list per beat: index 0 is before the first key, index i is
// after stroke i-1.
export async function replay(beats: TimedBeat[]): Promise<Snapshot[][]> {
  const ex = await load();
  return beats.map(({ from, strokes }) => {
    ex.misstype_wasm_reset();
    let committed = "";
    const shots: Snapshot[] = [EMPTY];
    for (const stroke of strokes) {
      const { code, key } = keyFor(stroke.label);
      const c = write(ex, code);
      const k = write(ex, key);
      ex.misstype_wasm_handle_key(c.ptr, c.len, k.ptr, k.len, 0, 0, EPOCH + (from + stroke.frame) / FPS);
      ex.misstype_wasm_free(c.ptr);
      ex.misstype_wasm_free(k.ptr);

      const s = readState(ex);
      if (s.lastCommit) {
        committed += s.lastCommit;
        ex.misstype_wasm_clear_committed();
      }
      const preedit: string = s.preedit ?? "";
      const showing = s.showsCandidates && s.candidates?.length > 0;
      shots.push({
        committed,
        preedit,
        segments: s.segments?.length ? s.segments : preedit ? [[0, preedit.length]] : [],
        focus: s.focus ?? null,
        caret: Math.max(0, Math.min(preedit.length, s.caret ?? preedit.length)),
        candidates: showing ? s.pageCandidates ?? [] : [],
        selected: showing ? s.pageSelected ?? -1 : -1,
        selectionKeys: s.selectionKeys ?? [],
        keysActive: !!s.keysActive,
      });
    }
    return shots;
  });
}
