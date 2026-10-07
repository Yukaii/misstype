// Narration for story.json via ElevenLabs. This sends only the narration
// lines written in story.json (never decoder input or user text) and logs
// every request. Output: public/voice/<lang>/<beat>.mp3 + manifest.json with
// per-phrase caption timings taken from the character alignment.
//
//   ELEVENLABS_API_KEY=... npm run voiceover [-- --lang en] [--force]
//
// The voice is story.json voices.<lang> (ELEVENLABS_VOICE_ID overrides it).
//
// Lines whose text, voice and model are unchanged are not re-requested.
import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";

const root = path.resolve(import.meta.dirname, "..");
const story = JSON.parse(fs.readFileSync(path.join(root, "story.json"), "utf8"));
const argv = process.argv.slice(2);
const lang = argv.includes("--lang") ? argv[argv.indexOf("--lang") + 1] : "zh";
const voice = story.voices[lang];
if (!voice) {
  console.error(`no voices.${lang} in story.json`);
  process.exit(1);
}
const outDir = path.join(root, "public/voice", lang);
const manifestPath = path.join(outDir, "manifest.json");

const apiKey = process.env.ELEVENLABS_API_KEY;
const voiceId = process.env.ELEVENLABS_VOICE_ID || voice.voiceId;
const modelId = process.env.ELEVENLABS_MODEL_ID || voice.modelId;
if (!apiKey || !voiceId) {
  console.error(`Set ELEVENLABS_API_KEY and a voice (ELEVENLABS_VOICE_ID or story.json voices.${lang}.voiceId).`);
  process.exit(1);
}

fs.mkdirSync(outDir, { recursive: true });
const old = fs.existsSync(manifestPath) ? JSON.parse(fs.readFileSync(manifestPath, "utf8")) : {};
const force = argv.includes("--force");
const manifest = {};

for (const base of story.beats) {
  const beat = lang === "zh" ? base : { ...base, ...base[lang] };
  if (!beat.narration) continue;
  const hash = crypto.createHash("sha256")
    .update(JSON.stringify([beat.narration, voiceId, modelId, voice.languageCode]))
    .digest("hex").slice(0, 16);
  const file = `${beat.id}.mp3`;
  if (!force && old[beat.id]?.hash === hash && fs.existsSync(path.join(outDir, file))) {
    manifest[beat.id] = old[beat.id];
    console.log(`= ${lang}/${beat.id} (cached)`);
    continue;
  }

  console.log(`→ ElevenLabs ${modelId}: ${lang}/${beat.id} (${beat.narration.length} chars)`);
  const body = { text: beat.narration, model_id: modelId };
  if (voice.languageCode) body.language_code = voice.languageCode;
  const res = await fetch(
    `https://api.elevenlabs.io/v1/text-to-speech/${voiceId}/with-timestamps?output_format=mp3_44100_128`,
    {
      method: "POST",
      headers: { "xi-api-key": apiKey, "Content-Type": "application/json" },
      body: JSON.stringify(body),
    },
  );
  if (!res.ok) {
    console.error(`  HTTP ${res.status}: ${await res.text()}`);
    process.exit(1);
  }
  const data = await res.json();
  const a = data.alignment;
  if (!a?.characters?.length) {
    console.error(`  no alignment returned by ${modelId}; captions need it`);
    process.exit(1);
  }
  fs.writeFileSync(path.join(outDir, file), Buffer.from(data.audio_base64, "base64"));
  manifest[beat.id] = {
    file,
    hash,
    durationSec: a.character_end_times_seconds.at(-1),
    captions: phrases(a),
  };
}

fs.writeFileSync(manifestPath, JSON.stringify(manifest, null, 2) + "\n");
console.log(`wrote ${path.relative(root, manifestPath)}`);

// Split at Chinese/English punctuation; each phrase spans its characters'
// spoken time. Trailing punctuation stays on screen with its phrase.
function phrases(a) {
  const out = [];
  let text = "", start = null, end = 0;
  a.characters.forEach((ch, i) => {
    if (start === null && ch.trim()) start = a.character_start_times_seconds[i];
    text += ch;
    end = a.character_end_times_seconds[i];
    if (/[，。、！？；：,.!?;:]/.test(ch)) {
      if (text.trim()) out.push({ text: text.trim(), startSec: start ?? end, endSec: end });
      text = ""; start = null;
    }
  });
  if (text.trim()) out.push({ text: text.trim(), startSec: start ?? end, endSec: end });
  return out;
}
