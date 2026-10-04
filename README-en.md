# Misstype (隨打注音)

[繁體中文](README.md) | **English**

Misstype is an experiment in low-interference text capture: two split touch surfaces (initially simulated in software) let a user type from muscle memory without stopping to aim at precise keys or choose Chinese candidates. A phonetic trace is captured first, then reconstructed into Chinese, English, or mixed text after a pause or explicit commit.

The first target is Bopomofo (Zhuyin), with English mixing and a local decoder. The project begins as a software prototype so that interaction, decoding quality, and latency can be measured before designing hardware.

## Documents

- [Project outline](docs/project-outline.md): product intent, milestones, experiments, and success criteria.
- [Technical architecture](docs/architecture.md): layers, event contracts, decoding pipeline, and deployment choices.
- [Cross-platform adapter contract](docs/cross-platform.md): platform adapter specifications, delivery rules, and conformance scenarios.
- [Linux (fcitx5) port plan](docs/linux-port.md): status, toolchain, dev container, and roadmap for Linux.
- [Competitor comparison and feature research](docs/competitors-en.md): Traditional Chinese feature matrix, baseline positioning, and tracking workflow.
- [Decoding and composition engines technical survey](docs/decoding-engines-en.md): Algorithms, trade-offs, and architectures across DAG, Bigram, Rime, and unified penalty lattices.
- [Packaging, installer and updates](docs/release.md): DMG installer, Sparkle auto-update, signing and release steps.
- [Development guide](AGENTS.md): working loop, privacy rules, and definition of done.

The design takes inspiration from [Qingjian](https://github.com/qingjian-team/qingjian), especially its platform-independent core and delayed whole-phrase reconstruction. Misstype is a separate experiment; compatibility with Qingjian is a milestone, not a promise.

## macOS IME prototype

The native macOS prototype is available as a SwiftPM InputMethodKit bundle. It uses a pinned, checksum-verified McBopomofo-derived dictionary at build time, then performs local phrase segmentation and conservative fuzzy rescue without network access or per-syllable candidate selection.

```sh
swift test
./script/build_and_run.sh --build-only
./script/install_ime.sh
```

After installation, select **隨打注音** (`Misstype Bopomofo`) from the macOS input-source menu. Type with the normal Zhuyin keyboard:
- **Continuous typing & optional tones**: tones are optional, and continuous typing converts as you go (only the syllable still being typed stays in Bopomofo). Tone keys finish syllables and Space represents the first tone.
- **Commit**: Return commits exactly what is shown, unfinished Bopomofo included (注音文 works); Shift+Return sends raw typed Bopomofo.
- **Candidate selection**: Down/Tab (or Left arrow to walk back to an earlier word) enters candidate selection mode, where home-row keys `asdfghjk` pick from the candidate panel (configurable in Preferences; they type Zhuyin outside this mode). Escape leaves the selection mode; outside selection mode, Escape cancels the composition.
- **Symbols & English toggle**: Shift+digit and Shift+= [ ] ` type full-width symbols (`！＠＃＄％︿＆＊（）＋｛｝～`). Backspace edits the raw composition; tapping Shift or pressing Shift-Space commits and toggles Chinese / English mode.
- **My dictionary**: while typing, Shift+←/→ marks syllables of the converted text and Return adds the phrase (a name, jargon) to your own dictionary; Return on the same mark removes it. Settings → My Dictionary (macOS) is a plain-text editor over `user_dictionary.tsv`; on Linux edit `~/.local/share/mistype/user_dictionary.tsv` directly.
- **Learning**: Candidate selections are learned locally per word, and single characters are learned in context with the preceding word.

The diagnostic path exercises the packaged dictionary without an IME client:

```sh
dist/MistypeIME.app/Contents/MacOS/MistypeIME --decode su3cl3
```

To build a release DMG (installer app) and Sparkle update archive, see [Packaging, installer and updates](docs/release.md).

The installer keeps the previous bundle at `.cache/MistypeIME-previous.app` when replacing an existing installation. Disable the source with `swift run -c release MistypeSourceTool disable` if needed.

### Releases

Pushing a `v*` tag runs `.github/workflows/release.yml`, which tests, builds a universal (`arm64` + `x86_64`) bundle via `script/package_release.sh`, and publishes `Mistype-<version>.dmg` to GitHub Releases. The same script runs locally (`./script/package_release.sh 0.2.0`). Users drag `MistypeIME.app` onto the `Input Methods` link in the DMG (`/Library/Input Methods`, admin password required), then log out/in or add it under System Settings → Keyboard → Input Sources.

Signing is optional and driven by repository secrets:

| Secret | Purpose |
| --- | --- |
| `MACOS_CERT_P12_BASE64`, `MACOS_CERT_PASSWORD` | Developer ID Application certificate (`.p12`, base64) |
| `NOTARY_KEY_P8_BASE64`, `NOTARY_KEY_ID`, `NOTARY_ISSUER_ID` | App Store Connect API key for `notarytool` |

Without them the DMG is ad-hoc signed and Gatekeeper blocks it on other machines; run `xattr -dr com.apple.quarantine "/Library/Input Methods/MistypeIME.app"` after installing. A self-signed certificate does not avoid this; only a Developer ID signature plus notarization does.

## Linux (fcitx5) port

Misstype supports Linux via an fcitx5 addon built on top of the platform-neutral `MistypeCore` and C ABI (`MistypeCAPI`):

```sh
# Build and run headless test suite in the Docker dev container
script/linux/dev.sh 'script/linux/build.sh && script/linux/test_fcitx5.sh'
```

See [Linux port documentation](docs/linux-port.md) and [Cross-platform specification](docs/cross-platform.md) for details.

## Run the M0 replay

The initial slice uses Python 3.11+ and has no runtime dependencies. It is the capture/touch prototype used to explore coordinate-based input; decoding behavior lives in the Swift `MistypeCore` package, the single source of truth:

```sh
PYTHONPATH=src python -m unittest discover -s tests -v
PYTHONPATH=src python -m mistype.cli examples/hello.jsonl
PYTHONPATH=src python -m mistype.cli examples/keyboard-ni.jsonl
PYTHONPATH=src python -m mistype.cli examples/touch-ni-hao.jsonl
PYTHONPATH=src python tools/bench.py
```

The fixture format is JSONL so traces can be recorded, redacted, diffed, and replayed independently of the eventual UI or hardware. Replayable phrase fixtures (touch + keyboard, with expected text in `manifest.json`) live under `tests/fixtures/`.

## License

MIT (see `LICENSE`). The bundled dictionary data comes from McBopomofo (MIT) and libtabe (BSD-style); see `THIRD_PARTY_NOTICES.md`.
