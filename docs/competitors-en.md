# Competitor comparison and feature research

[繁體中文](competitors.md) | **English**

Snapshot 2026-10-04. Sources are each project's public README, release page
or website, plus one press summary for ZingIME (its site shows only a
tagline). Claims below are what the projects say about themselves; none were
installed or benchmarked. Overlap between rows is expected: several projects
share ancestry (Yahoo KeyKey/OpenVanilla, McBopomofo, libchewing).

This document is not an IME scorecard or feature-matrix contest. It serves as a
design baseline: [vChewing](https://github.com/vChewing/vChewing-macOS) provides a mature,
stable reference for daily usability and candidate flow, while Misstype focuses on testing two specific
experimental directions: learned mixed Chinese/English input and paired fuzzy correction.


> **TODO before going public:** this page is a 2026-10-04 snapshot and must
> be refreshed first. Re-check every release version and download size
> (competitors ship weekly; KeyKey changed twice in one week), re-verify the
> `-` cells in the feature matrix and the ZingIME claims (price, AI, on-disk
> size), measure Misstype's own macOS binary and replace the "~6 MB data"
> placeholder, cover the projects listed under "Gaps in this research", and
> drop or soften anything we cannot source. Also confirm tone and licence
> wording are fair to each project.

## Projects

| | Platforms | Zhuyin engine | Mixed zh/en without switch | Learning | AI / network | Download | License / price |
| --- | --- | --- | --- | --- | --- | --- | --- |
| [Ari IME](https://github.com/kaiyasi/Ari-IME) | Linux (fcitx5), WASM core | libchewing phrase model, 11 layouts | Yes: keys show as themselves until they form a complete, toned syllable | Weighted personal dictionary | None, offline | 0.2 MB `.deb` (engine only) | GPL-3.0 |
| [ChiaKey](https://github.com/chiakich/ChiaKey) | macOS (stable), Windows (preview), iOS (experimental core) | Yahoo KeyKey lineage, bigram model; also Cangjie, Sucheng, `.cin` | Only what Zhuyin allows inherently | Tracks user choices; imports KeyKey user dictionary | None stated | 50.2 MB macOS `.pkg` | BSD-3-Clause |
| [Bopomix](https://github.com/lmanchu/bopomix) | macOS 13+, Apple Silicon | McBopomofo engine fork (Swift), Dachen only | Yes: letters that cannot form a syllable become English on the spot; Tab completes English (SCOWL list) | Local English-word learning | None; sentence-level AI reranking researched, not built | 6.6 MB `.dmg` | MIT |
| [KeyKey (琦琦)](https://github.com/polobread/KeyKey/releases) | macOS 15+, Windows 11, Linux (fcitx5), iOS, Android | Yahoo 2012 codebase, 30 domain phrase libraries; also Cangjie | Not advertised | Smart phrase composition with learning | Says no network access | 38.2 MB macOS `.pkg.zip` | BSD; v1.3.1 released 2026-10-02 |
| [ZingIME 晶晶](https://zingime.com/) | macOS, Apple Silicon | Zhuyin, 400k+ curated words | Yes (headline feature): same input state, no Caps Lock toggle; 220k-word English dictionary with Tab completion | Not stated | On-device "AI character selection" reading whole-sentence context (在/再); no cloud | 271.6 MiB `.dmg` | Paid, 14-day trial (press summary, unverified) |
| **Misstype** (this repo) | macOS IMK, Linux fcitx5 | McBopomofo lexicon, Dachen, Swift `MistypeCore` | Yes, `mixedEnglish` (macOS default off) | Learning + user dictionary | None by default; optional Jev LLM assist, opt-in | ~6 MB of data, no model (see below) | not yet released |

### Download sizes (measured 2026-10-04)

Release assets read from the GitHub API (`size` field) and, for ZingIME, a
HEAD request to its public download link (`Content-Length` 284,823,372 B =
271.6 MiB, `ZingIME-2026100301.dmg`). Nothing was installed, so on-disk size
after install is unknown.

| Project | Asset | Size | Notes |
| --- | --- | --- | --- |
| Ari IME v2.7.0 | `fcitx5-ari-ime_amd64.deb` | 0.2 MB | engine only; libchewing and its data come from the system, so not comparable. WASM core v2.6.4: 2.2 MB |
| Bopomix v0.1.0 | `Bopomix-0.1.0.dmg` | 6.6 MB | macOS, McBopomofo-derived data and English list |
| ChiaKey v1.2.6 | `ChiaKey-1.2.6.pkg` | 50.2 MB | macOS; Windows beta Setup.exe is 27.1 MB |
| KeyKey v1.3.1 | macOS `.pkg.zip` | 38.2 MB | Windows x64 setup 87 MB, zip 122 MB; Linux data `.deb` 27.3 MB + fcitx5 `.deb` 0.1 MB. Grew from 37.8 / 62.6 / 23.2 MB in v1.3.0 |
| ZingIME 2026100301 | `.dmg` | 271.6 MiB | ~41x Bopomix; the bundled model is the likely cause (inference, not measured) |
| Misstype | no release yet | ~6 MB data, binary unmeasured | `lexicon.tsv` 4.8 MB, `english.tsv` 0.9 MB, `toneless.tsv` 0.1 MB, `Resources/` 0.14 MB |

Bopomix is the fairest comparison: the same McBopomofo lexicon plus an
English list ships in 6.6 MB, so our ~6 MB of data is in line with an IME
that has no model.

Misstype's size is the runtime data only, measured from `.cache/` and
`Resources/` on 2026-10-04: `lexicon.tsv` 4.8 MB, `english.tsv` 0.9 MB,
`toneless.tsv` 0.1 MB, `Resources/` 0.14 MB. The compiled macOS binary was
not measured (this checkout builds on Linux only), so the total is a lower
bound.

## Technical feature matrix

`Y` = stated by the project, `-` = not stated or not found (not proof of
absence), `n/a` = not applicable. Unverified cells come from README/website
text only.

| Capability | Ari | ChiaKey | Bopomix | KeyKey | ZingIME | Misstype |
| --- | --- | --- | --- | --- | --- | --- |
| Zhuyin | Y | Y | Y (Dachen) | Y | Y | Y (Dachen) |
| Other layouts (Eten, Hsu, Dvorak…) | Y (11) | - | - | - | - | - |
| Cangjie / Sucheng / `.cin` tables | - | Y | - | Cangjie | - | - |
| Sentence-level phrase model | libchewing | bigram | McBopomofo | Y | "AI" | lexicon DP + learning |
| Tone optional (toneless typing) | - | - | - | - | - | Y |
| Edit repair (transpose, neighbor, insert/delete) | - | - | - | - | - | Y |
| Touch / coordinate-aware fuzzy | - | - | - | - | - | v1 in core, not wired to a surface |
| Mixed zh/en, no mode switch | Y | - | Y | - | Y | Y (v1) |
| English typo recovery | - | - | - | - | - | Y |
| English completion (Tab) | - | - | Y | - | Y | - |
| English word learning | - | - | Y | - | - | - |
| Personal learning | Y | Y | Y | Y | - | Y |
| User dictionary editor | - | Y (import) | - | Y (custom vocab) | - | Y (Shift+←/→, Settings) |
| Syllable cursor / re-pick inside preedit | Y | - | - | - | - | Y |
| Reconversion of committed text | Y | - | - | - | - | - |
| Chunked auto-commit while composing | - | - | - | - | - | Y |
| Raw trace kept / replayable | - | - | - | - | - | Y (capture side) |
| Simplified/Traditional switch | - | - | - | Y | - | - |
| Offline by default | Y | Y | Y | Y | Y | Y |
| LLM / model assist | - | - | researched | - | on-device | optional, opt-in (Jev) |
| macOS | - | Y | Y | Y | Y | Y |
| Windows | - | preview | - | Y | - | - |
| Linux | Y (fcitx5) | - | - | Y (fcitx5) | - | Y (fcitx5) |
| iOS / Android | - | iOS (experimental) | - | Y / Y | - | - |
| Portable core | WASM | - | - | - | - | C ABI + Swift core |
| Test discipline stated | sanitizers, fuzzing, coverage | - | - | - | - | conformance C1–C13, sweeps |
| Licence | GPL-3.0 | BSD-3 | MIT | BSD | proprietary | see repo |

## Per project

### Ari IME

Fcitx5 on Linux, C++20 over libchewing. Idea: every key shows as itself
until it forms a complete, toned syllable, so `acer螢幕` types straight
through. Strong on layouts (11), reconversion, whole-preedit re-selection,
and engineering hygiene (sanitizers, fuzzing). Weak spots relative to us:
needs a tone to commit a syllable (no toneless typing), no typo repair, Linux
only. Closest rival on Linux; the best source of ideas for the mixed-input
rule and reconversion.

### ChiaKey

Revival of Yahoo KeyKey/OpenVanilla for macOS, with a Windows TSF preview and
an experimental iOS core. Breadth of input methods (Zhuyin, Cangjie, Sucheng,
`.cin`) and a KeyKey user-dictionary import are its draws. Mixing English is
only whatever Zhuyin already allows. Worth studying for the Windows TSF and
iOS core split.

### Bopomix

McBopomofo fork in Swift, macOS 13+ Apple Silicon, Dachen only. Rule-based
language detection (letters that cannot form a syllable become English),
SCOWL English list, Tab completion and local English learning. Same
engine and lexicon source as ours, so its mixed-input behavior is the most
directly comparable. Sentence-level AI reranking is researched, not shipped.

### KeyKey (琦琦輸入法)

Maintained from Yahoo's 2012 open-source code; the widest platform spread
(macOS, Windows, Linux, iOS, Android). 30 domain phrase libraries; says it
makes no network connection. v1.3.1 shipped 2026-10-02, the most active
release cadence of the five. The mobile apps are the only touch-screen
precedent here, though nothing indicates coordinate-aware decoding.

### ZingIME (晶晶輸入法)

Paid macOS app, Apple Silicon, 14-day trial. Headline: mixed Chinese/English
in one input state, plus on-device "AI" homophone correction from whole-
sentence context, 400k+ curated words, 220k-word English dictionary, and
English Tab completion. The 271.6 MiB download suggests the model and
dictionaries are bundled (inference, not measured). Mixed input and context
selection are the same ground our `MixedDecode` and Jev assist cover; the
size and price are the contrast with our small offline lexicon.

For an algorithmic and architectural breakdown across composition and decoding engines (DAG, Bigram, Rime, and unified lattices), see [Decoding and composition engines technical survey](decoding-engines-en.md).

## Where Misstype stands

[vChewing](https://github.com/vChewing/vChewing-macOS) serves as our long-term baseline for compatibility, candidate flow, and day-to-day stability. Rather than attempting to match vChewing's full feature set, Misstype focuses on two specific differentiators: **learned mixed Chinese/English typing** (adoption, false switches, latency, and improvement after learning) and **paired fuzzy correction** (matching keyboard edits and touch-coordinate evidence to candidate readings while preserving replayable raw traces). Both claims need fixed-phrase, de-identified input fixtures and cross-platform conformance checks.

- **Mixed input.** Ari, Bopomix and ZingIME all treat this as the main
  selling point, so it is table stakes for the Zhuyin audience, not a
  differentiator. Our `MixedDecode` also recovers one-letter English typos,
  which none of the three advertise. Ari's rule (a complete toned syllable is
  the only trigger) is simpler and deterministic; ours is a scored decision
  and costs ~110–130 ms per keystroke on toneless mixed input. Ari is the
  reference for whether a simpler rule loses much quality.
- **Whole-sentence decode.** ZingIME's sentence-context homophone fix and
  Bopomix's unbuilt "整句 AI 選字" match what the lexicon decoder plus
  optional Jev assist already do; ours is offline-first and observable.
- **Fuzzy input.** No project lists keyboard edit repair (transpose,
  neighbor, tone tolerance) or any coordinate-aware touch decoding. That
  stays our open ground, but the touch benefit is unproven until the human
  tap-spread measurement exists.
- **Platforms.** KeyKey and ChiaKey cover mobile today; we have macOS plus
  Linux fcitx5 under shared conformance scenarios. Ari's WASM core is a
  precedent for the portable-core route.
- **Capture-first / raw trace.** None of these keep a replayable raw trace;
  they are conventional keyboard IMEs. This is the product premise, not a
  feature gap.

## Feature ideas worth evaluating

Each needs a hypothesis and a replayable check before adoption (AGENTS.md,
working loop).

1. **Tab completion for English words** (Bopomix, ZingIME). We recognise
   English but do not complete. Experiment: top-1 completion hit rate from
   the FrequencyWords list at 2–4 typed letters, versus keystrokes saved.
2. **Learned English words** (Bopomix). Brand names and jargon fall outside
   the pinned list. Needs the same opt-in and export rule as other learning.
3. **Alternate layouts** (Ari: 11, ChiaKey: also Cangjie/Sucheng). We target
   Dachen. Eten/Hsu cost is mostly key-to-syllable tables; check against
   the conformance scenarios before promising it.
4. **Domain phrase packs** (KeyKey: 30 libraries). Could be cheap lexicon
   overlays; measure against the existing sentence set before adding data.
5. **Reconversion of committed text** (Ari). Reopen committed Chinese for
   re-selection; conflicts with "capture first" only if it forces choices.
6. **Importing other user dictionaries** (ChiaKey imports KeyKey). A TSV
   import into `user_dictionary.tsv` is small and reversible.
7. **Whole-text candidate re-selection** (Ari). We already have a syllable
   cursor; compare reachability and keystrokes.

## Gaps in this research

- ZingIME details come from a search-result summary; the press article
  returned 403 and the site is a one-line page. Re-check before quoting.
- Bopomix README sub-pages were unreachable (404); the tone-handling and
  roadmap claims are from the repo front page only.
- The matrix marks `-` where a feature was not mentioned; it can be wrong
  in the competitors' favour. Verify a cell before using it in a claim.
- No head-to-head typing measurements exist. Comparing latency or accuracy
  needs the same phrase set run through each IME, which is out of scope until
  real-typing data exists.
- Not covered: Rime/Squirrel, vChewing, McBopomofo itself, Gboard, system
  Zhuyin. Add them if the comparison is used for positioning.
