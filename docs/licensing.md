# Distribution licensing

Misstype's own code remains MIT. Third-party components and dictionary data
keep their original licenses; `THIRD_PARTY_NOTICES.md` is the inventory and
records the applicability to each platform. `english.tsv` is distributed
separately as CC BY-SA 4.0 content, including when downloaded by the web demo.
The demo video's ElevenLabs-generated narration and music are non-commercial
only and are excluded from the MIT grant; see `THIRD_PARTY_NOTICES.md`.

Hypothesis (2026-10-07): keeping notices in the repository is insufficient
unless the actual app, Linux install tree, and website carry them. The smallest
check is to build each distribution and compare its notice payload against
the source files. Decoder behavior is unaffected.

## Packaging

The macOS and Linux packaging steps copy `LICENSE`, `THIRD_PARTY_NOTICES.md`,
and all of `third_party/`. The Sparkle snapshot is pinned in
`third_party/Sparkle/sources.json`; the macOS build fails if its license differs
from the resolved binary artifact. On a Sparkle upgrade, review and refresh
the snapshot, its manifest, and any affected attribution together.

The website's `prebuild` and `predev` npm hooks run
`script/prepare_site_notices.mjs` after dependencies are installed. They copy
the common notices, Hairline's license, and the installed WASI shim and Vite
license files to `site/public/`, and generate `licenses.html` with the notice
texts and CC license links. Vite copies this payload into `site/dist/`.
Both language footers link to the page. Pages CI also rebuilds when the root
license, notice inventory, or generator changes.

The fcitx5 libraries remain system dependencies linked dynamically; their
LGPL text and use notice accompany the addon. If they are bundled or modified
in future, providing the corresponding source and satisfying the applicable
LGPL redistribution conditions is additional work.

## Manual verification

Run `npm run build` from `site/`. Confirm that `site/dist/licenses.html` and
every linked local license/attribution file exist; compare the copied files
byte-for-byte against `LICENSE`, `THIRD_PARTY_NOTICES.md`, `third_party/`,
`site/hairline/LICENSE`, and the installed npm license files. Open the Chinese
and English footer links, including when served beneath a project URL prefix.

Run `./script/build_and_run.sh --build-only`. Check the notices beneath
`dist/MisstypeIME.app/Contents/Resources/`, including
`third_party/Sparkle/LICENSE`; compare Sparkle's copy against
`.build/artifacts/sparkle/Sparkle/LICENSE`. The installer and update archive
must preserve this resource directory when copying the app.

After a staged Linux `cmake --install`, check the same common notice payload
under `share/doc/misstype/`, including `third_party/fcitx5/LGPL-2.1-or-later.txt`
and its `README.md`. Do not check only the build directory.

This documents the notice distribution checks. It does not establish ownership
of every upstream contribution or replace review of changed upstream terms.

Verified 2026-10-07: the website build, macOS `--build-only` bundle, and Linux
Docker release build plus staged install all passed. Their common notice files
matched the repository byte-for-byte; the website's three additional license
files matched Hairline and the installed npm packages. Both footer links and
all local links on the license page worked at the root and under `/misstype/`.
The Python suite passed all 68 tests. `--build-only` also preserved the running
IME process. The DMG and update ZIP were not regenerated for this check.
