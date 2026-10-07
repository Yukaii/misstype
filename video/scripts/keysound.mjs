// Synthesized mechanical-keyboard sounds, so the video carries no third-party
// sound effects. A keystroke is a few short events (switch click, bottom-out,
// release), each a high-passed noise transient plus damped resonances for the
// plate and case. Profiles approximate common switch families.
//
//   node scripts/keysound.mjs --samples   # out/samples/switch-<profile>.wav
import fs from "node:fs";
import path from "node:path";

export const RATE = 44100;

// at: seconds into the keystroke; noise: [amplitude, decay/s, high-pass 0..1];
// rings: [frequency Hz, amplitude, decay/s].
export const PROFILES = {
  // Clicky (Cherry MX Blue-like): a sharp click jacket before bottom-out.
  blue: [
    { at: 0, noise: [0.9, 900, 0.85], rings: [[3600, 0.35, 380], [5200, 0.15, 500]] },
    { at: 0.014, noise: [0.55, 320, 0.6], rings: [[1900, 0.25, 220], [480, 0.25, 90]] },
    { at: 0.085, noise: [0.3, 700, 0.8], rings: [[3100, 0.12, 450]] },
  ],
  // Tactile (Brown-like): no click, a crisp bottom-out with a bright tick.
  brown: [
    { at: 0, noise: [0.25, 600, 0.7], rings: [] },
    { at: 0.01, noise: [0.75, 380, 0.65], rings: [[2400, 0.3, 260], [620, 0.25, 110]] },
    { at: 0.08, noise: [0.22, 650, 0.75], rings: [[2700, 0.08, 400]] },
  ],
  // Linear, clacky (Red/Speed Silver-like on an aluminium plate): bright and short.
  clacky: [
    { at: 0, noise: [0.85, 520, 0.75], rings: [[2900, 0.32, 300], [1300, 0.2, 180], [700, 0.15, 120]] },
    { at: 0.075, noise: [0.28, 800, 0.8], rings: [[3300, 0.1, 500]] },
  ],
  // Lubed linear in a gasket mount ("thock"): deeper, but still with a top end.
  thock: [
    { at: 0, noise: [0.7, 300, 0.45], rings: [[380, 0.45, 70], [1150, 0.22, 160], [2300, 0.08, 260]] },
    { at: 0.08, noise: [0.18, 600, 0.6], rings: [[900, 0.08, 300]] },
  ],
};

// Variant v changes pitch and level slightly so repeated keys do not sound
// like one sample on a loop. big: Enter/Space, with a lower stabilizer body.
export function synth(profile, v = 0, big = false) {
  const events = PROFILES[profile];
  if (!events) throw new Error(`unknown key sound ${profile}; one of ${Object.keys(PROFILES)}`);
  const n = Math.round(RATE * 0.16);
  const out = new Float32Array(n);
  let seed = 1 + v * 7919 + (big ? 104729 : 0);
  const rand = () => ((seed = (seed * 16807) % 2147483647) / 2147483647) * 2 - 1;
  const detune = 1 + ((v * 37) % 9 - 4) * 0.012;
  const level = 1 - ((v * 13) % 5) * 0.04;

  for (const e of events) {
    const start = Math.round(e.at * RATE);
    const [amp, decay, hp] = e.noise;
    let prevX = 0, y = 0;
    for (let i = start; i < n; i++) {
      const t = (i - start) / RATE;
      const x = rand();
      y = hp * (y + x - prevX); // one-pole high-pass
      prevX = x;
      let s = y * amp * Math.exp(-t * decay);
      for (const [f, a, d] of e.rings) {
        const freq = f * detune * (big ? 0.8 : 1);
        s += Math.sin(2 * Math.PI * freq * t) * a * Math.exp(-t * d);
      }
      if (big) s += Math.sin(2 * Math.PI * 210 * t) * 0.25 * amp * Math.exp(-t * 45);
      out[i] += s * level;
    }
  }
  return out;
}

export function wav(samples) {
  let peak = 0;
  for (const s of samples) peak = Math.max(peak, Math.abs(s));
  const gain = peak > 0 ? 0.85 / peak : 0;
  const buf = Buffer.alloc(44 + samples.length * 2);
  buf.write("RIFF", 0); buf.writeUInt32LE(36 + samples.length * 2, 4); buf.write("WAVE", 8);
  buf.write("fmt ", 12); buf.writeUInt32LE(16, 16); buf.writeUInt16LE(1, 20); buf.writeUInt16LE(1, 22);
  buf.writeUInt32LE(RATE, 24); buf.writeUInt32LE(RATE * 2, 28); buf.writeUInt16LE(2, 32); buf.writeUInt16LE(16, 34);
  buf.write("data", 36); buf.writeUInt32LE(samples.length * 2, 40);
  samples.forEach((s, i) => buf.writeInt16LE(Math.round(Math.max(-1, Math.min(1, s * gain)) * 32767), 44 + i * 2));
  return buf;
}

// A short typing phrase: twelve keys at the video's pace, then Enter.
function phrase(profile) {
  const out = new Float32Array(Math.round(RATE * 2.6));
  let t = 0.1;
  for (let k = 0; k < 13; k++) {
    const big = k === 12;
    if (big) t += 0.45;
    const s = synth(profile, k % 4, big);
    const at = Math.round(t * RATE);
    for (let i = 0; i < s.length && at + i < out.length; i++) out[at + i] += s[i];
    t += 0.13 + (((k * 7) % 5) - 2) * 0.015;
  }
  return out;
}

if (process.argv.includes("--samples")) {
  const dir = path.resolve(import.meta.dirname, "../out/samples");
  fs.mkdirSync(dir, { recursive: true });
  for (const p of Object.keys(PROFILES)) {
    fs.writeFileSync(path.join(dir, `switch-${p}.wav`), wav(phrase(p)));
    console.log(`out/samples/switch-${p}.wav`);
  }
}
