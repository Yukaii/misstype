// Background music via ElevenLabs Music. This sends only story.json
// music.prompt (never decoder input or user text) and logs every request.
// Output: public/music/candidates/bed-<n>.mp3, loudness-normalized (ffmpeg)
// so the volumes in Demo.tsx hold for any of them; copy the one you like to
// public/music/bed.mp3, which the video picks up and ducks under narration.
//
//   npm run music [-- --count 3]
import { execFileSync } from "node:child_process";
import fs from "node:fs";
import path from "node:path";

const root = path.resolve(import.meta.dirname, "..");
const { music } = JSON.parse(fs.readFileSync(path.join(root, "story.json"), "utf8"));
const argv = process.argv.slice(2);
const count = argv.includes("--count") ? Number(argv[argv.indexOf("--count") + 1]) : 1;

const apiKey = process.env.ELEVENLABS_API_KEY;
if (!apiKey) {
  console.error("Set ELEVENLABS_API_KEY.");
  process.exit(1);
}

const outDir = path.join(root, "public/music/candidates");
fs.mkdirSync(outDir, { recursive: true });
const start = fs.readdirSync(outDir).filter((f) => /^bed-\d+\.mp3$/.test(f)).length;

for (let n = start + 1; n <= start + count; n++) {
  console.log(`→ ElevenLabs music_v1: ${music.lengthSec}s (${music.prompt.length} chars)`);
  const res = await fetch("https://api.elevenlabs.io/v1/music?output_format=mp3_44100_128", {
    method: "POST",
    headers: { "xi-api-key": apiKey, "Content-Type": "application/json" },
    body: JSON.stringify({
      prompt: music.prompt,
      music_length_ms: music.lengthSec * 1000,
      model_id: "music_v1",
      force_instrumental: true,
    }),
  });
  if (!res.ok) {
    console.error(`  HTTP ${res.status}: ${await res.text()}`);
    process.exit(1);
  }
  const file = path.join(outDir, `bed-${n}.mp3`);
  const raw = `${file}.raw.mp3`;
  fs.writeFileSync(raw, Buffer.from(await res.arrayBuffer()));
  execFileSync("ffmpeg", ["-loglevel", "error", "-y", "-i", raw, "-af", "loudnorm=I=-16:TP=-1.5",
    "-ar", "44100", "-b:a", "128k", file]);
  fs.rmSync(raw);
  console.log(`  wrote ${path.relative(root, file)}`);
}
