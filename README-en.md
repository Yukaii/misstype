<div align="center">
  <img src="Resources/MisstypeIcon.png" alt="Misstype logo" width="96" height="96">
  <br><sub><i>Type Zhuyin. Skip the tones.</i></sub>

  <h1>Misstype (隨打注音)</h1>

  <p>A Zhuyin input method with optional tones and automatic typo repair.<br>Zig core · macOS (IMK) and Linux (fcitx5) · offline · MIT</p>

  <p>
  <a href="https://github.com/Yukaii/misstype/actions/workflows/ci.yml"><img alt="CI" src="https://github.com/Yukaii/misstype/actions/workflows/ci.yml/badge.svg"></a>
  <a href="https://github.com/Yukaii/misstype/releases/latest"><img alt="Release" src="https://img.shields.io/github/v/release/Yukaii/misstype?sort=semver"></a>
  <a href="LICENSE"><img alt="License: MIT" src="https://img.shields.io/badge/license-MIT-blue"></a>
  <img alt="Core: Zig" src="https://img.shields.io/badge/core-Zig-f7a41d">
  <img alt="Platforms: macOS, Linux" src="https://img.shields.io/badge/platforms-macOS%20%C2%B7%20Linux-lightgrey">
  </p>

  <p><a href="README.md">繁體中文</a> · <b>English</b> · <a href="docs/architecture.md">Architecture</a> · <a href="CONTRIBUTING.md">Contributing</a> · <a href="docs/development.md">Development</a></p>
</div>

Misstype is a Zhuyin (Bopomofo) input method built around two things:

- **Tone-optional continuous typing**: skip the tones and the per-character candidate picking. Keep typing and the whole sentence is assembled from context.
- **Automatic typo repair**: neighboring-key slips, swapped order, and extra or missing keys are repaired toward what you meant, without affecting correct input.

Everything runs locally; no network is needed. The project is still experimental: it validates the typing model in software before deciding on custom hardware.

> [!TIP]
> No install needed: [try it in your browser](https://misstype.yukai.dev/editor/). The online editor runs the same Zig core (WebAssembly).

> [!IMPORTANT]
> This project is developed entirely with LLMs, and will keep being developed, delivered and tested by LLMs. Bug reports and feature prompts are welcome, and regular contributions are very welcome too, but be prepared for them to be closed and redone from scratch XD

## Start here (humans and agents)

1. Read [AGENTS.md](AGENTS.md) first (working loop, privacy rules, canonical commands), then [docs/architecture.md](docs/architecture.md) and [docs/project-outline.md](docs/project-outline.md).
2. Build and run the core tests (the first run downloads the pinned Zig):

   ```sh
   cd core-zig && "$(../script/zig/bootstrap.sh)" build test
   ```

   Per-layer and per-platform checks: [CONTRIBUTING.md](CONTRIBUTING.md#checks) and [docs/development.md](docs/development.md).
3. Before opening a PR read [CONTRIBUTING.md](CONTRIBUTING.md) and use the PR template. Agents open a PR only when their human asks, and disclose the model and harness in it.

## Why another input method?

Because I wanted one for myself. It started with wanting to type without even opening my eyes: keep going, skip the tones, fingers not too precise, and let the input method guess what I meant.

Back when I used Rime, teaching it a word meant typing it on purpose, picking the right characters and deleting the extras, and I never found a quick key for editing the dictionary. Yahoo KeyKey and vChewing felt much smoother, so "<kbd>Shift</kbd>+<kbd>←</kbd>/<kbd>→</kbd> marks, <kbd>Return</kbd> adds the word" here follows their feel.

Tones are optional and typos are repaired by default; turn that off if you want it strict. Many keyboard layouts, Simplified/Traditional switching and Cangjie/Quick are not planned for now. If you just want a mature, stable daily input method, vChewing is great, use that; if you have the same lazy itch, come play.

## How it compares

> [!NOTE]
> Comparison tables like this inherently skew toward "features we built, so our product always wins"—take it with a grain of salt XD.
>
> This is not an IME scorecard or feature-matrix contest. Mature projects (such as vChewing, McBopomofo, Rime, ChiaKey, etc.) each excel in daily stability, deep feature sets, diverse layout support, or cross-platform maturity. This table serves strictly as a design baseline and reference coordinate for Misstype's experimental directions (toneless continuous typing, fuzzy typo correction, and unswitched mixed Chinese/English).

Based on each project's public description (snapshot 2026-10-04, not hands-on tested). `-` means no public mention was found, not that the feature is absent.

| | Misstype | ChiaKey | vChewing | McBopomofo | Rime (Squirrel etc.) |
| --- | --- | --- | --- | --- | --- |
| Tones optional | ✓ | - | partial (Zhuyin Furious Typing, off by default) | - | ✓ |
| Typo repair (neighbor keys, swaps, extra/missing) | ✓ | - | - | - | partial (order within a syllable; the engine also has an off-by-default typo corrector) |
| Chinese/English mixing, no mode switch | ✓ (off by default on macOS) | - | ✓ | - | - (needs a switch) |
| English typo repair | ✓ | - | - | - | - |
| User dictionary and learning | ✓ | ✓ | ✓ | ✓ | ✓ |
| Offline by default | ✓ | ✓ | ✓ | ✓ | ✓ |
| Platforms | macOS, Linux | macOS, Windows (preview) | macOS | macOS, Windows, Linux, web (separate projects) | macOS, Windows, Linux |

For the full comparison (platforms, licenses, download sizes) see [Competitor comparison](docs/competitors-en.md).

## Install

Want to try it first? The [online editor](https://misstype.yukai.dev/editor/) needs no install.

### macOS

Download `Misstype-<version>.dmg` from [GitHub Releases](https://github.com/Yukaii/misstype/releases/latest), open it and run **Install Misstype**. The input method installs into your user folder (no admin password) and updates itself through Sparkle. After the first install, log out and back in, then pick **隨打注音** (`Misstype Bopomofo`) from the input-source menu or System Settings → Keyboard → Input Sources.

### Linux

Supported as an fcitx5 addon sharing the same core as macOS. See the [Linux port](docs/linux-port.md) for install and status. An experimental IBus engine (GNOME's default framework) is also available: [IBus port](docs/ibus-port.md).

On Arch Linux / Omarchy, install [`fcitx5-misstype-git`](https://aur.archlinux.org/packages/fcitx5-misstype-git) from AUR:

```sh
yay -S fcitx5-misstype-git
```

This package builds the latest upstream Git source rather than a fixed release.
Restart fcitx5 after installation and add **Misstype** in `fcitx5-configtool`.
See [package build, activation and removal](docs/arch-linux.md) for details;
the recipe lives in `linux/aur/PKGBUILD`.

To build from source see [Development, build and release](docs/development.md).

## Usage

Key bindings and behavior (continuous typing, candidates, symbols, user dictionary, learning) are in the [user manual](docs/usage-en.md).

## Repository layout

| Path | What lives there |
| --- | --- |
| `core-zig/` | The single decoder and editing `Session`, exposed through a C ABI and a wasm32-wasi build |
| `Sources/` | macOS only: IMK adapter, Settings UI, installer (no decoding rules) |
| `linux/fcitx5/` | fcitx5 addon and GTK dictionary editor over the same core |
| `packages/misstype-wasm/` | npm browser bindings |
| `src/misstype/` | Python capture/touch prototype (reference for touch semantics only) |
| `tests/`, `tools/` | Golden files, replay fixtures, measurement scripts |
| `docs/` | Architecture, cross-platform contract (C1–C15), design notes |
| `site/` | Landing page and web editor (separate from this README by design) |

## License

Misstype's own code is **MIT** (see [`LICENSE`](LICENSE)). Third-party code and
dictionary data keep their own licenses: McBopomofo (MIT), libtabe (BSD-style),
the National Academy for Educational Research word-frequency table (CC BY 4.0),
and the English word list (CC BY-SA 4.0); the macOS build uses Sparkle and the
Linux build links fcitx5. See [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md)
for sources, licenses and where each applies.

The demo video's narration and background music (`video/public/voice/`,
`video/public/music/`, `site/media/demo*.mp4`) are **not** MIT: they were
generated on a free ElevenLabs plan, so they are for non-commercial use only and
need the ElevenLabs credit shown with them. See the same notices file.
