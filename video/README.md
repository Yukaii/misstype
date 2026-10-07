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
npm run voiceover         # narration + captions via ElevenLabs (optional)
npm run render:site       # site/media/demo.mp4 + demo-poster.jpg (committed)
```

The landing page embeds `site/media/demo.mp4`; re-run `render:site` and
commit both files when the story, voice or decoder output changes. The
poster is the `DemoPoster` still (the neighbor-key beat, without captions).

`site/public` must be built first (wasm and lexicon, see `site/README.md`);
`npm run prepare-assets` copies what the video needs and synthesizes the
key-click sound.

## Editing the story

Everything is in `story.json`. A beat either shows a title card (`title`,
`subtitle`) or types `keys`:

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

`npm run voiceover` sends **only the `narration` lines in story.json** to
ElevenLabs (logged per request) and writes `public/voice/*.mp3` plus
`manifest.json` with phrase timings from the character alignment. These are
committed, so renders do not need an API key. Beats then
stretch to fit their line, and captions follow the speech. Without a
manifest, each beat shows its narration as a plain caption.

Configure with `ELEVENLABS_API_KEY` and `ELEVENLABS_VOICE_ID` (in the
repository's gitignored `.env`, or the environment); `ELEVENLABS_MODEL_ID`
overrides `voice.modelId` (default `eleven_v4`). Unchanged lines are cached;
`npm run voiceover -- --force` regenerates them.

## Music

Put a licensed track at `public/music/bed.mp3` (gitignored); it is picked up
automatically and ducked under the narration. Record its source and licence
here before publishing a video that uses it.
