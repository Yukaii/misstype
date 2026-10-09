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
> size), cover the projects listed under "Gaps in this research", and
> drop or soften anything we cannot source. Also confirm tone and licence
> wording are fair to each project.

## Projects

| | Platforms | Zhuyin engine | Mixed zh/en without switch | Learning | AI / network | Download | License / price |
| --- | --- | --- | --- | --- | --- | --- | --- |
| [Ari IME](https://github.com/kaiyasi/Ari-IME) | Linux (fcitx5), WASM core | libchewing phrase model, 11 layouts | Yes: keys show as themselves until they form a complete, toned syllable | Weighted personal dictionary | None, offline | 0.2 MB `.deb` (engine only) | GPL-3.0 |
| [ChiaKey](https://github.com/chiakich/ChiaKey) | macOS (stable), Windows (preview), iOS (experimental core) | Yahoo KeyKey lineage, bigram model; also Cangjie, Sucheng, `.cin` | Only what Zhuyin allows inherently | Tracks user choices; imports KeyKey user dictionary | None stated | 50.2 MB macOS `.pkg` | BSD-3-Clause |
| [Bopomix](https://github.com/lmanchu/bopomix) | macOS 13+, Apple Silicon | McBopomofo engine fork (Swift), Dachen only | Yes: letters that cannot form a syllable become English on the spot; Tab completes English (SCOWL list) | Local English-word learning | None; sentence-level AI reranking researched, not built | 6.6 MB `.dmg` | MIT |
| [KeyKey (琦琦)](https://github.com/polobread/KeyKey/releases) | macOS 15+, Windows 11, Linux (fcitx5), iOS, Android | Yahoo 2012 codebase, 30 domain phrase libraries; also Cangjie | Not advertised | Smart phrase composition with learning | Says no network access | 38.2 MB macOS `.pkg.zip` | Mixed: Yahoo source BSD-3-Clause, platform frontends MIT; v1.3.1 released 2026-10-02 |
| [ZingIME 晶晶](https://zingime.com/) | macOS, Apple Silicon | Zhuyin, 400k+ curated words | Yes (headline feature): same input state, no Caps Lock toggle; 220k-word English dictionary with Tab completion | Not stated | On-device "AI character selection" reading whole-sentence context (在/再); no cloud | 271.6 MiB `.dmg` | Paid, 14-day trial (press summary, unverified) |
| [vChewing](https://github.com/vChewing/vChewing-macOS) | macOS 12+ (Aqua memorial build from 10.9) | Tiehen (鐵恨) chord engine; most Zhuyin layouts and pinyin schemes of any Zhuyin IME (its claim); separate Simplified/Traditional corpora | Yes: mixed-input fallback mode (Zhuyin keys first tried as readings, else fall back to English); since v4.8.6 ASCII shows in the preedit | Decaying-memory model (POM) observes selections and feeds composition; user phrases, custom associated phrases | Not stated; sandboxed | 12.6 MB `.pkg` (v4.8.6, 2026-09-29) | MulanPSL-2.0 (core modules LGPLv3); modified builds may not keep the product name |
| [McBopomofo 小麥注音](https://github.com/openvanilla/McBopomofo) | macOS 13+; Windows (win-mcbopomofo), Linux (fcitx5-mcbopomofo) and web/ChromeOS are separate repos in the same org | Gramambular 2 composer, unigram-only language model, Dachen | Not advertised | Records user selection overrides; user and excluded phrases | Not stated | 5.3 MB `.zip` (v3.1.1, 2026-09-02) | MIT |
| [Rime](https://rime.im) (Squirrel / Weasel / ibus-fcitx-rime) | macOS (Squirrel), Windows (Weasel), Linux (ibus/fcitx-rime) | librime schema-driven engine; Zhuyin is the rime-bopomofo schema (Dachen and "dynamic ability" layouts, dictionary depends on terra_pinyin); Cangjie, Quick and others are separate schemas | Needs an ASCII/Chinese mode switch (the Zhuyin schema ships an `ascii_mode` switch) | librime ships a user dictionary (`user_dictionary`) | None, offline | Squirrel 25.5 MB `.pkg` (1.1.2); Weasel 12.4 MB `.exe` (0.17.4) | GPL-3.0 (Squirrel, Weasel); librime BSD-3-Clause |
| **Misstype** (this repo) | macOS IMK, Linux fcitx5 | McBopomofo lexicon, Dachen, Swift `MisstypeCore` | Yes, `mixedEnglish` (macOS default off) | Learning + user dictionary | None; decoding is offline only (an opt-in LLM assist was removed 2026-10-09) | `.dmg` 4.4 MB (v0.0.1, universal), no model | MIT |

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
| Misstype v0.0.1 | `Misstype-0.0.1.dmg` | 4.4 MB | macOS universal (arm64 + x86_64) installer app; the Sparkle update archive `MisstypeIME-0.0.1.zip` is 3.6 MB |

Bopomix is the fairest comparison: the same McBopomofo lexicon plus an
English list ships in 6.6 MB, and our 4.4 MB universal installer is in line
with an IME that has no model.

Misstype's size is the size of the GitHub Releases asset
(`Misstype-0.0.1.dmg`, 4,351,872 B), measured on 2026-10-04. It is a
compressed installer, like the competitors' download sizes, not an on-disk size.

## Technical feature matrix

`Y` = stated by the project, `-` = not stated or not found (not proof of
absence), `n/a` = not applicable. Unverified cells come from README/website
text only.

| Capability | Ari | ChiaKey | Bopomix | KeyKey | ZingIME | vChewing | McBopomofo | Rime | Misstype |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| Zhuyin | Y | Y | Y (Dachen) | Y | Y | Y | Y (Dachen) | Y (schema) | Y (Dachen) |
| Other layouts (Eten, Hsu, Dvorak…) | Y (11) | - | - | - | - | Y (most) | - | - | - |
| Cangjie / Sucheng / `.cin` tables | - | Y | - | Cangjie | - | - | - | Y (Cangjie, Quick schemas) | - |
| Sentence-level phrase model | libchewing | bigram | McBopomofo | Y | "AI" | Y (Megrez/Homa) | Y (unigram) | varies by schema | lexicon DP + learning |
| Tone optional (toneless typing) | - | - | - | - | - | partial (Zhuyin Furious Typing: auto syllable split, initials-only; off by default) | - | Y (schema text: tone and final may be omitted) | Y |
| Edit repair (transpose, neighbor, insert/delete) | partial (key order, repeated/invalid keys) | - | - | - | - | - | - | partial (schema: `free_order` order within a syllable, `abbrev` initial only; the engine also has an off-by-default `enable_correction`, see below) | Y |
| Touch / coordinate-aware fuzzy | - | - | - | - | - | - | - | - | v1 in core, not wired to a surface |
| Mixed zh/en, no mode switch | Y | - | Y | - | Y | Y (mixed-input fallback mode; ASCII shown in the preedit) | - | - (needs switch; rime-ice/frost pinyin schemas can mount an English word list, see below) | Y (v1) |
| English typo recovery | - | - | - | - | - | - | - | - | Y |
| English completion (Tab) | - | - | Y | - | Y | - | - | - | - |
| English word learning | - | - | Y | - | - | - | - | - | - |
| Personal learning | Y | Y | Y | Y (selection override + bigram; resettable) | - | Y (POM) | Y (selection override) | Y (user dictionary) | Y |
| User dictionary editor | - | Y (import) | - | Y (phrase editor; menu entry "Edit custom phrases…") | - | Y (phrase tidying) | Y (user phrases) | - | Y (Shift+←/→, Settings) |
| In-place add/remove-word gesture while composing | - | - | - | Shift+arrows select, Enter adds (the audit doc says the source retains it; not verified in the shipped build) | - | Y (Shift+←/→ marks; Enter boosts; Shift+Cmd+Enter nerfs; Backspace/Delete filters) | - | delete candidate only (Shift+Delete, Ctrl+K by default); no add gesture found | Y (Shift+←/→ marks, Return adds / removes on the same mark) |
| Syllable cursor / re-pick inside preedit | Y | - | - | - | - | - | - | - | Y |
| Reconversion of committed text | Y (Control+Alt+R) | - | - | - | - | - | - | - | - |
| Chunked auto-commit while composing | - | - | - | - | - | - | - | - | Y |
| Raw trace kept / replayable | - | - | - | - | - | - | - | - | Y (capture side) |
| Simplified/Traditional switch | - | - | - | - | - | Y (separate corpora) | - | Y (OpenCC filters: simplified, HK, TW glyphs) | - |
| Offline by default | Y | Y | Y | Y | Y | Y | Y | Y | Y |
| LLM / model assist | - | - | researched | - | on-device | - | - | - | - (removed 2026-10-09) |
| macOS | - | Y | Y | Y | Y | Y | Y | Y (Squirrel) | Y |
| Windows | - | preview | - | Y | - | - | Y (separate project) | Y (Weasel) | - |
| Linux | Y (fcitx5) | - | - | Y (fcitx5) | - | - | Y (fcitx5, separate project) | Y | Y (fcitx5) |
| iOS / Android | - | iOS (experimental) | - | Y / Y | - | - | - | - | - |
| Portable core | WASM | - | - | - | - | LibVanguard (separate engine repo) | - | librime | C ABI + Swift core |
| Test discipline stated | sanitizers, fuzzing, coverage | - | - | - | - | - | - | - | conformance C1–C13, sweeps |
| Licence | GPL-3.0 | BSD-3 | MIT | BSD-3 + MIT | proprietary (no source found; no matching GitHub repo) | MulanPSL-2.0 / LGPLv3 | MIT | GPL-3.0 / BSD-3 | see repo |

## Rime: the other schemas (2026-10-04)

Sources: `rime/librime` source, the `rime/*` schema repos, rime-ice (GPL-3.0) and rime-frost (GPL-3.0). Everything below comes from reading files; nothing was installed or run.

- **The engine has a typo corrector, off by default.** `src/rime/dict/corrector.cc` implements the per-schema `translator/enable_correction`: edit distance (delete and insert cost 2, adjacent transposition costs 2), neighbor-key substitution (QWERTY-adjacent keys cost 1, others 4), a fixed correction credibility of log(0.01), at most 4 corrections per query. I checked `rime-bopomofo`, `rime-luna-pinyin`, `rime-terra-pinyin`, `rime-double-pinyin`, `rime-prelude`, `rime-cangjie`, `rime-quick`, `rime-combo-pinyin`, `rime-pinyin-simp`, `rime-jyutping`, `rime-cantonese`, and every schema in rime-ice and rime-frost: none sets it to `true`. librime issues #1195 and #1120 ("suspected auto-correction", "auto-correction weight too high") suggest users or third-party configs turn it on (I read only the titles, not the threads). So Rime technically has neighbor/transpose/insert/delete repair, but the official Zhuyin schema does not use it.
- **The neighbor table is only left/right neighbors on the QWERTY letter and digit rows.** No vertical neighbors, no touch coordinates; whether it suits Dachen-mapped spellings was not verified.
- **Pinyin fuzzy sounds are fixed rules, not evidence-weighted.** `terra_pinyin` has `derive` rules (e.g. `ao`→`oa`, `ng`→`gn`, tone dropping, initial-only); rime-ice's zh/z, l/n, f/h fuzzy sounds are commented-out templates the user enables.
- **Mixed Chinese/English is a secondary translator, not free interleaving.** rime-ice and rime-frost mount `melt_eng` (an English word list; frost describes it as "a small set of common words") as a second `table_translator` on the pinyin schemas, so English words show up as candidates. Lua helpers (`cn_en_spacer`, `autocap_filter`) add spaces and capitalisation. This exists only in the pinyin schemas; rime-frost's `bopomofo*.schema.yaml` do not mount it.
- **rime-frost also ships Zhuyin schemas** (`bopomofo`, `bopomofo_express`, `bopomofo_tw`), same lineage as the official ones, with no extra tolerance that I could see.
- **The sentence language model is a plugin.** `rime-essay` is the shared vocabulary and frequencies; `librime-octagram` (BSD-3-Clause) is the grammar (n-gram) plugin. In the third-party benchmark `gaboolic/rime-schema-compare` (code and corpora open, report 2026-08-30, 3,466 Simplified-Chinese sentences from a Zhihu hot list), rime-frost scores 61.19% whole-sentence accuracy, 65.87% with grammar; rime-ice 53.29% / 59.09%; luna pinyin 47.49% (40.33% with grammar). These are Simplified pinyin numbers: **not comparable to Zhuyin and not our measurement.**
- **Mobile ports exist**: Trime (GPL-3.0), fcitx5-android (LGPL-2.1), Hamster (iOS, MIT, last push 2025-05). I only read their repo descriptions and did not check whether they pass touch coordinates to the engine, so touch-coordinate fuzzy stays `-`.
- **User dictionary**: librime's `user_dictionary` / `user_db` does the learning; the Zhuyin schema's `custom_phrase` is a fixed table and does not learn.

## Per project

### Ari IME

Fcitx5 on Linux, C++20 over libchewing. Idea: every key shows as itself
until it forms a complete, toned syllable, so `acer螢幕` types straight
through. Strong on layouts (11), reconversion, whole-preedit re-selection,
and engineering hygiene (sanitizers, fuzzing). Weak spots relative to us:
needs a tone to commit a syllable (no toneless typing), typo tolerance is
limited to key order and repeated/invalid keys, Linux only. Closest rival on Linux; the best source of ideas for the mixed-input
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
selection are the same ground our `MixedDecode` and sentence decoder cover; the
size and price are the contrast with our small offline lexicon.

For an algorithmic and architectural breakdown across composition and decoding engines (DAG, Bigram, Rime, and unified lattices), see [Decoding and composition engines technical survey](decoding-engines-en.md).

## Where Misstype stands

**Starting point:** this project began from "input with no fixed key position": continuous typing loose enough that you would not even open your eyes, with the decoder recovering roughly what you meant. It is also an LLM-era homebrew experiment: even an IME, a mature field, can be maintained by yourself. The comparison is a design reference, not a feature-count contest.

[vChewing](https://github.com/vChewing/vChewing-macOS) serves as our long-term baseline for compatibility, candidate flow, and day-to-day stability. Rather than attempting to match vChewing's full feature set, Misstype focuses on two specific differentiators: **learned mixed Chinese/English typing** (adoption, false switches, latency, and improvement after learning) and **paired fuzzy correction** (matching keyboard edits and touch-coordinate evidence to candidate readings while preserving replayable raw traces). Both claims need fixed-phrase, de-identified input fixtures and cross-platform conformance checks.

- **Mixed input.** Ari, Bopomix and ZingIME all treat this as the main
  selling point, and vChewing 4.8.6 ships a mixed-input fallback mode too, so it is table stakes for the Zhuyin audience, not a
  differentiator. Our `MixedDecode` also recovers one-letter English typos,
  which none of them advertise. Ari's rule (a complete toned syllable is
  the only trigger) is simpler and deterministic; ours is a scored decision
  and costs ~110–130 ms per keystroke on toneless mixed input. Ari is the
  reference for whether a simpler rule loses much quality.
- **Adding words in place.** vChewing already has the gesture we copied
  (Shift+← / → marks, Enter adds with a boost, Shift+Cmd+Enter nerfs,
  Backspace/Delete filters; read from its `InputHandler_HandleStates.swift`),
  so this is parity with vChewing and an advantage over Rime, where only
  deleting a candidate has a default key (Shift+Delete). It is not a new idea.
- **Whole-sentence decode.** ZingIME's sentence-context homophone fix and
  Bopomix's unbuilt "整句 AI 選字" match what the lexicon decoder already
  does; ours is offline-only and observable.
- **Fuzzy input.** Two projects do part of this, both from their own
  source: Ari accepts out-of-order keys (`su3` and `s3u` both give 你) and
  drops a repeated or invalid leading key once the rest forms a syllable;
  Rime's Zhuyin schema omits tones and finals and reorders keys within a
  syllable (`free_order`, `abbrev`). Neighbor-key substitution, insert/delete
  repair, costed edits against exact input and coordinate-aware touch
  decoding are not in any project we read. That stays our open ground, but
  the touch benefit is unproven until the human tap-spread measurement
  exists.
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
- Rime, vChewing and McBopomofo were added 2026-10-04 from their READMEs,
  the GitHub Releases API, LICENSE files, `algorithm.md`, the orgs' repo
  lists and the `rime-bopomofo` schema file. `-` still means "not found in
  those sources". The other official schemas and rime-ice/rime-frost were covered in
  "Rime: the other schemas"; other community schemas were not read; the Windows/Linux
  McBopomofo ports and vChewing's other engines were only confirmed to
  exist, not compared feature by feature. Still not covered: Gboard, system Zhuyin.
