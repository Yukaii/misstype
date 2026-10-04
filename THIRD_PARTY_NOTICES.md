# Third-party notices

Mistype's own code is MIT licensed (see `LICENSE`). The built app bundles
data derived from the projects below; their license texts live under
`third_party/` and are copied into `MistypeIME.app/Contents/Resources/third_party/`.

| Component | Used for | License | Text |
|---|---|---|---|
| [McBopomofo](https://github.com/openvanilla/McBopomofo) data (pinned in `third_party/McBopomofo/sources.json`) | `lexicon.tsv`: readings, phrase frequencies, heterophone ranks; `script/prepare_lexicon.py` ports the heterophone weighting of its `cook.py` | MIT, Copyright (c) 2011-2026 Mengjuei Hsieh et al. | `third_party/McBopomofo/LICENSE.txt` |
| 國家教育研究院《通用詞頻表》（定稿 1141208）, via the ChiaKey Lexicon subset (pinned in `third_party/NAER/sources.json`) | `toneless.tsv`: ranks single characters sharing a toneless Bopomofo base; the frequencies are not redistributed, only a reordering of Mistype's own scores | CC BY 4.0, 國家教育研究院 | `third_party/NAER/LICENSE.md` |
| libtabe `tsi.src` (via McBopomofo's `BPMFMappings.txt`) | multi-character phrases | BSD-style, Copyright (c) 1999 TaBE Project, Pai-Hsiang Hsiao; Computer Systems and Communication Lab, Institute of Information Science, Academia Sinica | `third_party/libtabe/COPYING` |
| hermitdave [FrequencyWords](https://github.com/hermitdave/FrequencyWords) English 50k (pinned in `third_party/FrequencyWords/sources.json`), from OpenSubtitles 2018 | `english.tsv`: English words and log-frequencies for recognizing English typed without a mode switch | Content CC BY-SA 4.0 (code MIT), Hermit Dave | `third_party/FrequencyWords/LICENSE.md` |

`english.tsv` is an adaptation of CC BY-SA 4.0 content: where it ships (the
app bundle, the Linux data directory) it is offered under CC BY-SA 4.0 with the
attribution above, separately from Mistype's MIT code.

The dictionary sources are downloaded at build time (checksum-verified) and
are not committed; only their manifest and license texts are.
