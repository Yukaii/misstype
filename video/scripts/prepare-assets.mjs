// Copies the decoder build from site/public (generated, see site/README.md)
// and synthesizes the key-click sound, so the video has no third-party audio
// besides what is added deliberately under public/music.
import fs from "node:fs";
import path from "node:path";

const root = path.resolve(import.meta.dirname, "..");
const site = path.resolve(root, "../site/public");
const decoderDir = path.join(root, "public/decoder");
fs.mkdirSync(decoderDir, { recursive: true });

for (const name of ["misstype.wasm", "lexicon.tsv", "toneless.tsv"]) {
  const from = path.join(site, name);
  const to = path.join(decoderDir, name);
  if (!fs.existsSync(from)) {
    console.error(`missing ${path.relative(root, from)}: build the site assets first (see site/README.md)`);
    process.exit(1);
  }
  const a = fs.statSync(from);
  if (!fs.existsSync(to) || fs.statSync(to).mtimeMs < a.mtimeMs) fs.copyFileSync(from, to);
}

// A short mechanical click: a filtered noise transient over a low thump.
const rate = 44100;
const n = Math.round(rate * 0.06);
const pcm = Buffer.alloc(44 + n * 2);
let seed = 1;
const rand = () => ((seed = (seed * 16807) % 2147483647) / 2147483647) * 2 - 1;
let lp = 0;
for (let i = 0; i < n; i++) {
  const t = i / rate;
  lp += 0.35 * (rand() - lp);
  const click = lp * Math.exp(-t * 180);
  const thump = Math.sin(2 * Math.PI * 140 * t) * Math.exp(-t * 60) * 0.5;
  const v = Math.max(-1, Math.min(1, (click + thump) * 0.8));
  pcm.writeInt16LE(Math.round(v * 32767), 44 + i * 2);
}
pcm.write("RIFF", 0); pcm.writeUInt32LE(36 + n * 2, 4); pcm.write("WAVE", 8);
pcm.write("fmt ", 12); pcm.writeUInt32LE(16, 16); pcm.writeUInt16LE(1, 20); pcm.writeUInt16LE(1, 22);
pcm.writeUInt32LE(rate, 24); pcm.writeUInt32LE(rate * 2, 28); pcm.writeUInt16LE(2, 32); pcm.writeUInt16LE(16, 34);
pcm.write("data", 36); pcm.writeUInt32LE(n * 2, 40);
fs.mkdirSync(path.join(root, "public/sfx"), { recursive: true });
fs.writeFileSync(path.join(root, "public/sfx/key.wav"), pcm);
console.log("assets ready: public/decoder, public/sfx/key.wav");
