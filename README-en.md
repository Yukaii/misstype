<div align="center">
  <img src="Resources/MisstypeIcon.png" alt="Misstype logo" width="96" height="96">
  <br><sub><i>Type Zhuyin without the tones.</i></sub>

  <h1>Misstype (隨打注音)</h1>

  <p>A tone-optional, typo-repairing Zhuyin input method.<br>Zig core · macOS (IMK) &amp; Linux (fcitx5, IBus) · Offline · MIT</p>

  <p>
  <a href="https://github.com/Yukaii/misstype/actions/workflows/ci.yml"><img alt="CI" src="https://github.com/Yukaii/misstype/actions/workflows/ci.yml/badge.svg"></a>
  <a href="https://github.com/Yukaii/misstype/releases/latest"><img alt="Release" src="https://img.shields.io/github/v/release/Yukaii/misstype?sort=semver"></a>
  <a href="LICENSE"><img alt="License: MIT" src="https://img.shields.io/badge/license-MIT-blue"></a>
  <img alt="Core: Zig" src="https://img.shields.io/badge/core-Zig-f7a41d">
  <img alt="Platforms: macOS, Linux" src="https://img.shields.io/badge/platforms-macOS%20%C2%B7%20Linux-lightgrey">
  </p>

  <p><a href="README.md">繁體中文</a> · <b>English</b> · <a href="docs/story.md">Story &amp; Technical Report</a> · <a href="docs/architecture.md">Architecture</a> · <a href="CONTRIBUTING.md">Contributing</a> · <a href="docs/development.md">Development</a></p>
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

1. Read [AGENTS.md](AGENTS.md) first (working loop, privacy rules, canonical commands), then [docs/story.md](docs/story.md), [docs/architecture.md](docs/architecture.md), and [docs/project-outline.md](docs/project-outline.md).
2. Build and run the core tests (the first run downloads the pinned Zig):

   ```sh
   cd core-zig && "$(../script/zig/bootstrap.sh)" build test
   ```

   See [CONTRIBUTING.md](CONTRIBUTING.md#checks) and [docs/development.md](docs/development.md) for full checks across platforms.
3. Read [CONTRIBUTING.md](CONTRIBUTING.md) and use the PR template before submitting a PR. Agents open a PR only when the user explicitly asks for one, disclosing the model and harness.

## Why another input method?

Because I wanted one for myself. It started with wanting to type without opening my eyes: skip the tones, let fingers land roughly, and let the IME guess the sentence I meant.

When I used Rime, teaching it a new word meant deliberately typing it, picking the right candidate, and deleting extra characters—I never learned if there was a shortcut to edit the dictionary quickly. Yahoo! KeyKey and vChewing felt much smoother; the `<kbd>Shift</kbd> + <kbd>←</kbd>/<kbd>→</kbd> select, <kbd>Return</kbd> add-word` shortcut here follows their feel.

Tones are optional and typo repair is on by default; you can turn them off if you prefer a strict IME. Alternative layouts, Simplified Chinese, and Cangjie/Quick are not planned. If you want a mature, dependable daily-driver IME, vChewing is great—use it! If you share the same lazy-typing itch, you're welcome to play along.

## Comparison with other Zhuyin IMEs

> [!NOTE]
> Comparisons like this inevitably highlight what their author chose to build. **Take this as a reference point, not a definitive verdict XD.**
>
> Established tools like vChewing, McBopomofo, Rime, and ChienChiu have deep strengths in daily stability, broad feature sets, alternative layouts, and platform reach. This table reflects design baselines for Misstype's experimental focus (tone-free typing, fuzzy repair, mixed language input), not a feature race.

Based on public project docs (snapshot 2026-10-04, unverified); `-` means not found in public docs, not necessarily absent.

| | Misstype | ChienChiu | vChewing | McBopomofo | Rime (Squirrel, etc.) |
| --- | --- | --- | --- | --- | --- |
| Optional tones | ✓ | - | partial (Bopomofo Rush, off by default) | - | ✓ |
| Typo repair (neighbor keys, swaps, extra/missing) | ✓ | - | - | - | partial (order within a syllable; the engine also has an off-by-default typo corrector) |
| Chinese/English mixing, no mode switch | ✓ (off by default on macOS) | - | ✓ | - | - (needs a switch) |
| English typo repair | ✓ | - | - | - | - |
| User dictionary and learning | ✓ | ✓ | ✓ | ✓ | ✓ |
| Offline by default | ✓ | ✓ | ✓ | ✓ | ✓ |
| Platforms | macOS, Linux | macOS, Windows (preview) | macOS | macOS, Windows, Linux, web (separate projects) | macOS, Windows, Linux |

For the full comparison (platforms, licenses, download sizes) see [Competitor comparison](docs/competitors-en.md).

For the full background—from the midnight bus ride idea and Jev model inspiration to the Zig engine rewrite and WebAssembly offline editor—see the [Story & Technical Report](docs/story.md) (or [read it online](https://misstype.yukai.dev/en/story/)).

## Install

Want to try it first? The [online editor](https://misstype.yukai.dev/editor/) needs no install.

### macOS

Download `Misstype-<version>.dmg` from [GitHub Releases](https://github.com/Yukaii/misstype/releases/latest), open it and run **Install Misstype**. The input method installs into your user folder (no admin password) and updates itself through Sparkle. After the first install, log out and back in, then pick **隨打注音** (`Misstype Bopomofo`) from the input-source menu or System Settings → Keyboard → Input Sources.

Release builds include GitHub Actions build provenance attestations; see [verifying provenance](docs/release.md#verify-build-provenance) for details.

### Linux

Supported as an fcitx5 addon sharing the same core as macOS. See the [Linux port](docs/linux-port.md) for install and status. An experimental IBus engine (GNOME's default framework) is also available: [IBus port](docs/ibus-port.md).

## Documentation

- [docs/story.md](docs/story.md): The Misstype story & technical report ([online version](https://misstype.yukai.dev/en/story/))
- [docs/architecture.md](docs/architecture.md): Core architecture and layer responsibilities
- [docs/zig-port.md](docs/zig-port.md): The Zig core rewrite rationale, architecture, and benchmarks
- [docs/development.md](docs/development.md): Local development, testing, and debugging
- [docs/project-outline.md](docs/project-outline.md): Evolution and milestones
- [docs/linux-port.md](docs/linux-port.md): Linux fcitx5 port details
- [docs/ibus-port.md](docs/ibus-port.md): Linux IBus port details
- [docs/competitors.md](docs/competitors.md): Competitor comparison and feature research
- [docs/editor.md](docs/editor.md): WebAssembly offline Markdown editor design
- [docs/release.md](docs/release.md): Release, signing, and verification workflows
