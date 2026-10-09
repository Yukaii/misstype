# Landing page

Two plain HTML pages built with Vite (no framework, no web fonts, no
trackers). `index.html` is Traditional Chinese, `en/index.html` English; both
share `style.css` and `demo.js`. Files in `public/` are copied as-is; the live
demo's `misstype.wasm` and lexicons there are generated (gitignored) by
`script/build_site_assets.sh`, which Pages runs before building. Run it once
before `npm run dev` if you want the demo to load locally. `media/` holds the
demo videos (Chinese and English) and their posters, rendered by `video/` (`npm run render:site` there)
and committed, since Pages does not render video. `video.js` replaces the
browser controls with a player in the page style (native controls remain
without JS). The keyboard beside
the hero is a Hairline line figure; see `hairline/README.md`.

```sh
cd site
npm ci
npm run dev       # local preview with reload
npm run build     # writes site/dist (what Pages publishes)
```

The examples under "打錯了沒關係，幫你修回來" are real decoder output (default
settings, no tones, Enter to commit), checked through the C ABI with
`tools/baseline/compare.py drive-misstype` on 2026-10-05. If the decoder or
lexicon changes, re-run them before editing the page; `demo.js` replays the
same list, so there is one place to update. Keys used (standard layout):

| example | keys | output |
| --- | --- | --- |
| no tones | `rupwu0wu0fucpcl` | 今天天氣很好 |
| swapped | `urpwu0wu0fucpcl` | 今天天氣很好 |
| missed key | `au/wu0ylg;r.2u0d9cjo` | 明天早上九點開會 |
| neighbor key | `vu,vu,du1;a;` | 謝謝你幫忙 |

Deployed by `.github/workflows/pages.yml` once Pages is enabled (see the
workflow header). The download button points at GitHub Releases `latest`,
which only works for visitors once the repository is public.

## Markdown editor (PWA)

`editor/` is an installable, offline-capable Markdown editor built on
[Wordgard](https://wordgard.net) with the same wasm decoder, for devices that
cannot host a custom IME (iPad with a hardware keyboard). See
[`docs/editor.md`](../docs/editor.md). `npm run build` also emits
`dist/editor/sw.js` and `manifest.webmanifest` (plugin in `vite.config.js`);
`node ../tests/editor_markdown_test.mjs` checks the Markdown serializer.

## Reuse the decoder

The low-level browser binding is prepared as the `misstype-wasm` npm
package (not yet published). It loads the same `misstype.wasm` and lexicon assets used here and
exposes key handling, state, candidate selection, commit, and settings without
requiring the site's editor or CSS. See
[`packages/misstype-wasm/README.md`](../packages/misstype-wasm/README.md) for a
minimal integration.
