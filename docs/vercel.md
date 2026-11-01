# Vercel deployments

The landing page (`/`, `/en/`) and the web editor (`/editor/`) are one static
site (`site/dist`). The Vercel project `misstype` (team `ykpersonal`) is
connected to this repository through Vercel's Git integration:

| Event | Result |
| --- | --- |
| Push to a branch / pull request | Preview deployment; the Vercel bot comments the URL on the PR |
| Push to `main` | Production deployment |

`vercel.json` holds the whole configuration: install and build commands,
output directory, and the `Access-Control-Allow-Origin: *` header that
`docs/embed.md` promises for `embed.js`, the wasm and the lexicons.

## Build

Vercel runs `script/build_site_assets.sh` (pinned Zig from `bootstrap.sh`,
lexicon from the pinned public sources, the same script Pages uses) and then
`npm run build` in `site/`, publishing `site/dist`. The assets are generated,
not committed (`site/public/` is gitignored), which is why the build command
cannot be just `vite build`.

GitHub Pages (`pages.yml`) builds the same site independently; the two do
not depend on each other.

## Cloud sync keys

The editor's Dropbox / Google Drive sync (`docs/editor.md`, Cloud sync) is
built in only when the project has `VITE_DROPBOX_APP_KEY` and/or
`VITE_GOOGLE_CLIENT_ID` set (public values). Each deployment origin's
`/editor/oauth.html` must be a registered redirect URI; preview URLs change per
deployment, so sync sign-in works on production and on a fixed preview alias only.

## Notes

- Previews of a private repository sit behind Vercel's deployment protection
  by default (log in or use a share link).
- Every push builds, including changes that do not touch the site; the build
  downloads Zig and the lexicon each time (no cache). Add an `ignoreCommand`
  if that becomes noisy.
- `.vercel/` (written by `vercel link`) is gitignored.
