# Vercel deployments

The landing page (`/`, `/en/`) and the web editor (`/editor/`) are one static
site (`site/dist`). `.github/workflows/pages.yml` publishes it to GitHub Pages
and, when enabled, to Vercel:

| Event | Result |
| --- | --- |
| Pull request (same repository) touching a path the workflow watches | Preview deployment, URL in the job summary and the `vercel-preview` environment |
| Push to `main` | Production deployment (`vercel-production`) |
| Manual run (`workflow_dispatch`) | Preview, or production when run on `main` |

Vercel receives the build the `build` job already made (`vercel deploy
--prebuilt`, Build Output API v3), so there is no second build and its image
needs neither Zig nor the lexicon download. The root `vercel.json` turns the
project's Git integration off for the same reason: connected, Vercel would
build the bare repository, which has no `site/public/` assets, and the demo
would 404. `script/vercel_output_config.json` carries the CORS header
`docs/embed.md` promises for `embed.js`, the wasm and the lexicons.

## One-time setup

1. Create a Vercel project (any framework preset; never import the repo for
   Git deployment, or disconnect it afterwards). Run `npx vercel link` in a
   scratch directory, or read the IDs from the project settings.
2. Add repository secrets `VERCEL_TOKEN` (an account token),
   `VERCEL_ORG_ID` and `VERCEL_PROJECT_ID` (from `.vercel/project.json`).
3. Set the repository variable `VERCEL_ENABLED=true`.

Until then the `vercel` job is skipped and the rest of the workflow is
unaffected.

## Limits

- Only pushes that reach the workflow deploy: a pull request, `main`, or a
  manual run. A branch without a PR has no preview.
- Fork PRs get none (no secrets). The Pages `build` job still runs for them.
- Preview deployments of a private repository are behind Vercel's deployment
  protection by default (log in or use a share link); that is intended.
- Not yet verified end to end: it needs a Vercel project and token. Check the
  first run's summary, then open `/editor/` and confirm the service worker
  registers and the demo loads `misstype.wasm`.
