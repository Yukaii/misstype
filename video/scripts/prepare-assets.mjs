// Copies the decoder build from site/public (generated, see site/README.md)
// and synthesizes the key sounds, so the video has no third-party audio
// besides what is added deliberately under public/music.
import fs from "node:fs";
import path from "node:path";
import { synth, wav } from "./keysound.mjs";

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

// Key sounds for story.json's keySound (scripts/keysound.mjs): four
// variants for ordinary keys, one for Enter/Space.
const story = JSON.parse(fs.readFileSync(path.join(root, "story.json"), "utf8"));
const sfx = path.join(root, "public/sfx");
fs.rmSync(sfx, { recursive: true, force: true });
fs.mkdirSync(sfx, { recursive: true });
for (let v = 0; v < 4; v++) fs.writeFileSync(path.join(sfx, `key-${v}.wav`), wav(synth(story.keySound, v)));
fs.writeFileSync(path.join(sfx, "key-big.wav"), wav(synth(story.keySound, 0, true)));
console.log(`assets ready: public/decoder, public/sfx (${story.keySound})`);
