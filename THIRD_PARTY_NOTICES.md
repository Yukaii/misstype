# Third-party notices

Misstype's own code is MIT licensed (see `LICENSE`). Third-party code and
dictionary data retain their respective licenses; the MIT license does not
replace the terms below. The dictionary rows apply to macOS, Linux, and the
website demo. Platform-specific components are identified separately.

| Component | Used for | License | Text |
|---|---|---|---|
| [McBopomofo](https://github.com/openvanilla/McBopomofo) data (pinned in `third_party/McBopomofo/sources.json`) | `lexicon.tsv`: readings, phrase frequencies, heterophone ranks; `script/prepare_lexicon.py` ports the heterophone weighting of its `cook.py` | MIT, Copyright (c) 2011-2026 Mengjuei Hsieh et al. | `third_party/McBopomofo/LICENSE.txt` |
| 國家教育研究院《通用詞頻表》（定稿 1141208）, via the ChiaKey Lexicon subset (pinned in `third_party/NAER/sources.json`) | `toneless.tsv`: ranks single characters sharing a toneless Bopomofo base; the frequencies are not redistributed, only a reordering of Misstype's own scores | CC BY 4.0, 國家教育研究院 | `third_party/NAER/LICENSE.md` |
| libtabe `tsi.src` (via McBopomofo's `BPMFMappings.txt`) | multi-character phrases | BSD-style, Copyright (c) 1999 TaBE Project, Pai-Hsiang Hsiao; Computer Systems and Communication Lab, Institute of Information Science, Academia Sinica | `third_party/libtabe/COPYING` |
| hermitdave [FrequencyWords](https://github.com/hermitdave/FrequencyWords) English 50k (pinned in `third_party/FrequencyWords/sources.json`), from OpenSubtitles 2018 | `english.tsv`: English words and log-frequencies for recognizing English typed without a mode switch | Content CC BY-SA 4.0 (code MIT), Hermit Dave | `third_party/FrequencyWords/LICENSE.md` |
| [Sparkle](https://github.com/sparkle-project/Sparkle) (resolved by `Package.resolved`; license snapshot in `third_party/Sparkle/sources.json`) | macOS only: bundled update framework | MIT plus BSD, MIT and zlib-style notices for embedded components; retain the complete upstream license | `third_party/Sparkle/LICENSE` |
| [fcitx5](https://github.com/fcitx/fcitx5) Core and Utils | Linux only: dynamically linked system libraries, not bundled | LGPL-2.1-or-later | `third_party/fcitx5/LGPL-2.1-or-later.txt` and `third_party/fcitx5/README.md` |
| [Hairline](https://github.com/lucasmarkes/hairline), kernel from commit `bc78224` | Website only: hero keyboard figure; kernel modified by appending an ES module export | MIT, Copyright (c) 2026 Lucas Marques | `site/hairline/LICENSE` (website copy: `third_party/Hairline/LICENSE`) |
| [browser_wasi_shim](https://github.com/bjorn3/browser_wasi_shim) (version in `site/package-lock.json`) | Website only: browser WASI runtime shim | MIT OR Apache-2.0; Misstype distributes it under the MIT option | Installed package's `LICENSE-MIT` (website copy: `third_party/browser_wasi_shim/LICENSE-MIT`) |
| [Vite](https://github.com/vitejs/vite) (version in `site/package-lock.json`) | Website build tool and generated browser helpers | MIT; the supplied upstream file also records Vite's bundled dependencies | Installed package's `LICENSE.md` (website copy: `third_party/Vite/LICENSE.md`) |

`english.tsv` is an adaptation of CC BY-SA 4.0 content: where it ships (the
app bundle, the Linux data directory, and the website's downloadable demo
assets) it is offered under [CC BY-SA 4.0](https://creativecommons.org/licenses/by-sa/4.0/)
with the attribution above, separately from Misstype's MIT code. Misstype
filters to lowercase ASCII alphabetic words and converts counts to normalized,
six-decimal natural-log probabilities. The source and change description
are also retained in `third_party/FrequencyWords/LICENSE.md`.

The Linux addon remains MIT licensed; its use of fcitx5 is covered by the LGPL.
Users may modify it and replace the shared libraries, including to debug their
modifications. Bundling or modifying those libraries in a future distribution
requires their corresponding source and the other applicable LGPL conditions.

## Distribution locations

- macOS: `MisstypeIME.app/Contents/Resources/` carries `LICENSE`, this notice,
  and `third_party/`, including Sparkle's complete upstream license. The
  installer and update archive contain this app. The build checks that the
  Sparkle license snapshot matches the resolved binary artifact.
- Linux: `${CMAKE_INSTALL_DOCDIR}` (normally `share/doc/misstype`) carries
  `LICENSE`, this notice, and `third_party/`, including the fcitx5 LGPL text.
- Website: `LICENSE`, this notice, `third_party/`, and a readable `licenses.html`
  ship alongside the demo assets. Both language footers link to the license
  page. The website's MIT notices are copied from Hairline and the installed
  npm packages on every `npm run build` (also `npm run dev`), so minification
  does not remove them from the distribution.

Copies of notices for components used on other platforms do not imply that
those components are present in a particular distribution. Build-only tools
(including Lightning CSS under MPL-2.0) are not shipped to website visitors;
using them to generate CSS does not relicense Misstype's own code or output.

The dictionary sources are downloaded at build time (checksum-verified) and
are not committed; only their manifest and license texts are.

## utf8proc (Zig core)

The Zig core statically links utf8proc 2.12.0 for Unicode grapheme boundaries.
Its unmodified source snapshot and checksums are in `third_party/utf8proc/`.
It is licensed under MIT, with the included Unicode data license; see
`third_party/utf8proc/LICENSE.md` and `vendor.json`. It adds no shared-library
or network dependency at runtime. Source: https://github.com/JuliaStrings/utf8proc.
