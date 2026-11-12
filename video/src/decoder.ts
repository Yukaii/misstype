// Drives the real decoder (site/public/misstype.wasm, copied into
// public/decoder by scripts/prepare-assets.mjs) through each beat's keys and
// records what the playground would draw after every key. This runs once, in
// calculateMetadata; render workers only receive the recorded snapshots.
// @ts-expect-error: plain-JS package without type declarations
import { MisstypeWasm } from "../../packages/misstype-wasm/src/index.js";
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

type Ime = {
  key(code: string, text: string, modifiers: number, phase: number, timestamp: number): boolean;
  state(): any;
  takeCommitted(): string;
  reset(): void;
};

async function load(): Promise<Ime> {
  const get = async (name: string) => {
    const res = await fetch(staticFile(`decoder/${name}`));
    if (!res.ok) throw new Error(`decoder/${name}: HTTP ${res.status} (run npm run prepare-assets)`);
    return res;
  };
  const [wasm, lexicon, toneless] = await Promise.all(
    ["misstype.wasm", "lexicon.tsv", "toneless.tsv"].map(get),
  );
  // The same binding the site uses (packages/misstype-wasm over misstype.h).
  return MisstypeWasm.fromBytes({
    wasm: await wasm.arrayBuffer(),
    lexicon: await lexicon.text(),
    toneless: await toneless.text(),
  });
}

// One snapshot list per beat: index 0 is before the first key, index i is
// after stroke i-1.
export async function replay(beats: TimedBeat[]): Promise<Snapshot[][]> {
  const ime = await load();
  return beats.map(({ from, strokes }) => {
    ime.reset();
    let committed = "";
    const shots: Snapshot[] = [EMPTY];
    for (const stroke of strokes) {
      const { code, key } = keyFor(stroke.label);
      ime.key(code, key, 0, 0, EPOCH + (from + stroke.frame) / FPS);
      const s = ime.state();
      if (s.lastCommit) committed += ime.takeCommitted();
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
