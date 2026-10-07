import story from "../story.json";

export const FPS = 30;

export type Lang = "zh" | "en";

// A beat's text in one language: `en` fields override the Chinese ones.
export type Beat = {
  id: string;
  holdSec: number;
  narration: string;
  label?: string;
  keys?: string;
  title?: string;
  subtitle?: string;
};

// One typed key. `label` is what the key strip shows (a Zhuyin symbol or a
// named key); `typo` marks keys written inside [...] in story.json.
export type Stroke = { label: string; typo: boolean; frame: number };

// Written by scripts/voiceover.mjs (public/voice/<lang>/manifest.json); times
// are seconds from the line's start. buildTimeline makes `file` a public path.
export type VoiceLine = {
  file: string;
  durationSec: number;
  captions: { text: string; startSec: number; endSec: number }[];
};
export type VoiceManifest = Record<string, VoiceLine>;

export type TimedBeat = {
  beat: Beat;
  from: number;
  durationInFrames: number;
  strokes: Stroke[]; // frames relative to `from`
  voice?: VoiceLine;
};

const LEAD_IN = 0.5; // seconds before the first key of a beat
const KEY_GAP = 0.13;
// The last beat lingers after its narration so the closing title can be read,
// then fades out fully (see TitleCard) before the video ends.
export const END_HOLD = 1.4;
export const END_FADE = 1.0;
export const END_BLANK = 0.5;

// Deterministic jitter so typing does not look metronomic but every render
// (and every render worker) sees the same timing.
function jitter(i: number): number {
  const x = Math.sin(i * 12.9898 + 78.233) * 43758.5453;
  return (x - Math.floor(x) - 0.5) * 0.08;
}

export function parseKeys(keys: string): Omit<Stroke, "frame">[] {
  const out: Omit<Stroke, "frame">[] = [];
  let typo = false;
  for (let i = 0; i < keys.length; i++) {
    const c = keys[i];
    if (c === "[") typo = true;
    else if (c === "]") typo = false;
    else if (c === "{") {
      const end = keys.indexOf("}", i);
      out.push({ label: keys.slice(i + 1, end), typo });
      i = end;
    } else out.push({ label: c, typo });
  }
  return out;
}

export function localize(lang: Lang): Beat[] {
  return story.beats.map(({ en, ...zh }) => (lang === "en" ? { ...zh, ...en } : zh));
}

export function buildTimeline(lang: Lang, voices: VoiceManifest = {}) {
  let from = 0;
  let n = 0;
  const all = localize(lang);
  const beats: TimedBeat[] = all.map((beat, i) => {
    let t = beat.keys ? LEAD_IN : 0;
    const strokes = beat.keys
      ? parseKeys(beat.keys).map((s) => {
          t += KEY_GAP + jitter(n++);
          // A beat before Enter, as a person would glance at the result.
          if (s.label === "Enter") t += 0.45;
          return { ...s, frame: Math.round(t * FPS) };
        })
      : [];
    const line = voices[beat.id];
    const voice = line && { ...line, file: `voice/${lang}/${line.file}` };
    const tail = i === all.length - 1 ? END_HOLD + END_FADE + END_BLANK : 0;
    const seconds = Math.max(t + beat.holdSec, (voice?.durationSec ?? 0) + 0.4) + tail;
    const timed = { beat, from, durationInFrames: Math.ceil(seconds * FPS), strokes, voice };
    from += timed.durationInFrames;
    return timed;
  });
  return { beats, durationInFrames: from };
}
