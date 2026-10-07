# Demo video

A [Remotion](https://www.remotion.dev) project for the product demo video.
Each frame's text comes from **the real decoder**: `calculateMetadata`
replays every beat's keys through `site/public/misstype.wasm` (the same
build as the playground) and the scenes draw the recorded snapshots. When the
decoder changes, re-render and the video follows.

```sh
npm install
npm run dev               # Remotion Studio (preview, scrubbing)
npm run render            # out/demo.mp4, 1920×1080
npm run render:vertical   # out/demo-vertical.mp4, 1080×1920 (Shorts/Reels)
npm run render:en         # English: out/demo-en.mp4 (and render:en:vertical)
npm run voiceover         # narration + captions via ElevenLabs (-- --lang en)
npm run render:site       # site/media/demo{,-en}.mp4 + posters (committed)
```

The landing pages embed `site/media/demo.mp4` (Chinese) and `demo-en.mp4`
(English); re-run `render:site` and commit the four files when the story,
voice or decoder output changes. Posters are the `DemoPoster` /
`DemoEnPoster` stills (the neighbor-key beat, without captions).

`site/public` must be built first (wasm and lexicon, see `site/README.md`);
`npm run prepare-assets` copies what the video needs and synthesizes the
key-click sound.

## Editing the story

Everything is in `story.json`. A beat either shows a title card (`title`,
`subtitle`) or types `keys`. A beat's `en` object holds its English title,
label and narration; the keys, and so the decoder output, are shared.

- Zhuyin symbols are typed on the standard keyboard layout (`src/keymap.ts`).
- `[ㄧㄐ]` marks keys that are mistakes; they are drawn red.
- `{Enter}`, `{Space}`, `{Down}`, `{Backspace}` are named keys.

Typing pace is fixed, with deterministic jitter (`src/timeline.ts`), so every
render is identical.

`keySound` picks the synthesized switch sound (`scripts/keysound.mjs`):
`blue` (clicky), `brown` (tactile), `clacky` (linear, bright) or `thock`
(lubed linear, deeper). `node scripts/keysound.mjs --samples` writes a short
typing phrase for each to `out/samples/`.

## Voiceover and captions

`npm run voiceover [-- --lang en]` sends **only the `narration` lines in
story.json** to ElevenLabs (logged per request) and writes
`public/voice/<lang>/*.mp3` plus `manifest.json` with phrase timings from the character alignment. These are
committed, so renders do not need an API key. Beats then
stretch to fit their line, and captions follow the speech. Without a
manifest, each beat shows its narration as a plain caption.

The voice per language is `voices.<lang>` in story.json (both currently Roy,
a Taiwanese Mandarin voice from the ElevenLabs library). Set
`ELEVENLABS_API_KEY` in the repository's gitignored `.env` or the
environment; `ELEVENLABS_VOICE_ID` / `ELEVENLABS_MODEL_ID` override the voice
and model (default `eleven_v4`). Unchanged lines are cached;
`npm run voiceover -- --force` regenerates them.

## Music

`npm run music [-- --count 3]` generates instrumental candidates from
story.json `music` (prompt and length) with ElevenLabs Music into
`public/music/candidates/` (gitignored), loudness-normalized to -16 LUFS.
Copy the chosen one to `public/music/bed.mp3`, which is committed like the
narration; it is picked up automatically, ducked under the narration and faded
out with the closing title. Eleven Music output may be used commercially on a
paid ElevenLabs plan; a track from elsewhere needs its source and licence
recorded here.
