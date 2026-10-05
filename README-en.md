# Misstype (隨打注音)

[繁體中文](README.md) | **English**

Misstype is a Zhuyin (Bopomofo) input method built around two things:

- **Tone-optional continuous typing**: skip the tones and the per-character candidate picking. Keep typing and the whole sentence is assembled from context.
- **Automatic typo repair**: neighboring-key slips, swapped order, and extra or missing keys are repaired toward what you meant, without affecting correct input.

Everything runs locally; no network is needed. The project is still experimental: it validates the typing model in software before deciding on custom hardware.

> [!IMPORTANT]
> This project is developed entirely with LLMs, and will keep being developed, delivered and tested by LLMs. Bug reports and feature prompts are welcome, and regular contributions are very welcome too, but be prepared for them to be closed and redone from scratch XD

## Why another input method?

Because I wanted one for myself.

It started with wanting to type without even opening my eyes: keep going, skip the tones, fingers not too precise, and let the input method guess what I meant.

Back when I used Rime, teaching it a word meant typing it on purpose, picking the right characters and deleting the extras, and I never found a quick key for editing the dictionary. Yahoo KeyKey and vChewing felt much smoother, so "Shift+←/→ marks, Return adds the word" here follows their feel.

Tones are optional and typos are repaired by default; turn that off if you want it strict. Many keyboard layouts, Simplified/Traditional switching and Cangjie/Quick are not planned for now.

If you just want a mature, stable daily input method, vChewing is great, use that. If you have the same lazy itch, come play.

## How it compares

Based on each project's public description (snapshot 2026-10-04, not hands-on tested). `-` means no public mention was found, not that the feature is absent.

| | Misstype | Ari IME | ChiaKey | Bopomix | KeyKey | ZingIME | vChewing | McBopomofo | Rime (Squirrel etc.) |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| Tones optional | ✓ | - | - | - | - | - | partial (Zhuyin Furious Typing, off by default) | - | ✓ |
| Typo repair (neighbor keys, swaps, extra/missing) | ✓ | partial (key order, repeated/invalid keys) | - | - | - | - | - | - | partial (order within a syllable; the engine also has an off-by-default typo corrector) |
| Chinese/English mixing, no mode switch | ✓ (off by default on macOS) | ✓ | - | ✓ | - | ✓ | ✓ | - | - (needs a switch) |
| English typo repair | ✓ | - | - | - | - | - | - | - | - |
| User dictionary and learning | ✓ | ✓ | ✓ | ✓ | ✓ | - | ✓ | ✓ | ✓ |
| Offline by default | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| Platforms | macOS, Linux | Linux | macOS, Windows (preview) | macOS | macOS, Windows, Linux, mobile | macOS | macOS | macOS, Windows, Linux, web (separate projects) | macOS, Windows, Linux |

For the full comparison (platforms, licenses, download sizes) see [Competitor comparison](docs/competitors-en.md).

## Documents

- [Project outline](docs/project-outline.md): product intent, milestones and experiments.
- [Competitor comparison](docs/competitors-en.md): feature matrix and baseline positioning.
- [Decoding engines survey](docs/decoding-engines-en.md): algorithms and trade-offs.
- [Technical architecture](docs/architecture.md): layers, event contracts and the decoding pipeline.
- [Development, build and release](docs/development.md): building from source, tests, signing and releasing.
- [Cross-platform contract](docs/cross-platform.md), [Linux port](docs/linux-port.md), [Packaging and updates](docs/release.md), [Agent guide](AGENTS.md).

The design takes inspiration from [Qingjian](https://github.com/qingjian-team/qingjian), especially its platform-independent core and delayed whole-phrase reconstruction. Misstype is a separate experiment; compatibility with Qingjian is a milestone, not a promise.

## Install

### macOS

Download `Misstype-<version>.dmg` from [GitHub Releases](https://github.com/Yukaii/misstype/releases/latest), open it and run **Install Misstype**. The input method installs into your user folder (no admin password) and updates itself through Sparkle. After the first install, log out and back in, then pick **隨打注音** (`Misstype Bopomofo`) from the input-source menu or System Settings → Keyboard → Input Sources.

### Linux

Supported as an fcitx5 addon sharing the same core as macOS. See the [Linux port](docs/linux-port.md) for install and status.

To build from source see [Development, build and release](docs/development.md).

## Usage

Type with the normal Zhuyin keyboard:
- **Continuous typing & optional tones**: tones are optional, and continuous typing converts as you go (only the syllable still being typed stays in Bopomofo). Tone keys finish syllables and Space represents the first tone.
- **Commit**: Return commits exactly what is shown, unfinished Bopomofo included (注音文 works); Shift+Return sends raw typed Bopomofo.
- **Candidate selection**: Down/Tab (or Left arrow to walk back to an earlier word) enters candidate selection mode, where home-row keys `asdfghjk` pick from the candidate panel (configurable in Preferences; they type Zhuyin outside this mode). Escape leaves the selection mode; outside selection mode, Escape cancels the composition.
- **Symbols & English toggle**: Shift+digit and Shift+= [ ] ` type full-width symbols (`！＠＃＄％︿＆＊（）＋｛｝～`). Backspace edits the raw composition; tapping Shift or pressing Shift-Space commits and toggles Chinese / English mode.
- **My dictionary**: while typing, Shift+←/→ marks syllables of the converted text and Return adds the phrase (a name, jargon) to your own dictionary; Return on the same mark removes it. Settings → My Dictionary (macOS) is a plain-text editor over `user_dictionary.tsv`, which uses the vChewing user-data format (`word reading`, one per line) and has an Import… button for vChewing files. To turn a plain word list into that format, use the third-party [online generator](https://vu.gh.miniasp.com/) by Will 保哥 ([source](https://github.com/doggy8088/vChewing-userdata-generator), MIT; not affiliated with this project). On Linux edit `~/.local/share/misstype/user_dictionary.tsv` directly.
- **Learning**: Candidate selections are learned locally per word, and single characters are learned in context with the preceding word.

## License

MIT (see `LICENSE`). The bundled dictionary data comes from McBopomofo (MIT) and libtabe (BSD-style); see `THIRD_PARTY_NOTICES.md`.
