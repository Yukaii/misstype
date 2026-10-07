# Landing page

Two plain HTML pages built with Vite (no framework, no web fonts, no
trackers). `index.html` is Traditional Chinese, `en/index.html` English; both
share `style.css` and `demo.js`. Files in `public/` are copied as-is. The
keyboard beside the hero is a Hairline line figure; see `hairline/README.md`.

```sh
cd site
npm ci
npm run dev       # local preview with reload
npm run build     # writes site/dist (what Pages publishes)
```

The examples under "打錯了，它幫你猜回來" are real decoder output (default
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
