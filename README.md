# Mistype

Mistype is an experiment in low-interference text capture: two split touch surfaces (initially simulated in software) let a user type from muscle memory without stopping to aim at precise keys or choose Chinese candidates. A phonetic trace is captured first, then reconstructed into Chinese, English, or mixed text after a pause or explicit commit.

The first target is Bopomofo (Zhuyin), with English mixing and a local decoder. The project begins as a software prototype so that interaction, decoding quality, and latency can be measured before designing hardware.

## Documents

- [Project outline](docs/project-outline.md): product intent, milestones, experiments, and success criteria.
- [Technical architecture](docs/architecture.md): layers, event contracts, decoding pipeline, and deployment choices.
- [Development guide](AGENTS.md): working loop, privacy rules, and definition of done.

The design takes inspiration from [Qingjian](https://github.com/qingjian-team/qingjian), especially its platform-independent core and delayed whole-phrase reconstruction. Mistype is a separate experiment; compatibility with Qingjian is a milestone, not a promise.

## Run the M0 replay

The first slice uses Python 3.11+ and has no runtime dependencies. It is the
capture/touch prototype and will be replaced; decoding behavior lives in the
Swift `MistypeCore` package, the single source of truth:

```sh
PYTHONPATH=src python -m unittest discover -s tests -v
PYTHONPATH=src python -m mistype.cli examples/hello.jsonl
PYTHONPATH=src python -m mistype.cli examples/keyboard-ni.jsonl
PYTHONPATH=src python -m mistype.cli examples/touch-ni-hao.jsonl
PYTHONPATH=src python tools/bench.py
```

The fixture format is JSONL so traces can be recorded, redacted, diffed, and replayed independently of the eventual UI or hardware. Replayable phrase fixtures (touch + keyboard, with expected text in `manifest.json`) live under `tests/fixtures/`.

The touch prototype is a versioned full-split mapper (`LAYOUT_VERSION = "full-split-1"` in `mistype.touch`): `nearest_key(surface, x, y)` accepts normalized coordinates and returns a replayable hypothesis, `layout_keys`/`key_position` expose the layout for rendering and tests, and tone-key touches emit exact codes so the normalizer can attach the tone.

For a complete simulator path, use `mistype.touch_session.TouchSession`, which exposes `touch`, `preview`, and `commit` while keeping event sequencing and normalization internal.

The eventual macOS version will be an InputMethodKit adapter around this core. System-wide IME integration is intentionally an M5 milestone; the simulator and replay pipeline run earlier on macOS without installing an input method.

## macOS IME prototype

The native prototype is now available as a SwiftPM InputMethodKit bundle. It
uses a pinned, checksum-verified McBopomofo-derived dictionary at build time,
then performs local phrase segmentation and conservative fuzzy rescue without
network access or per-syllable candidate selection.

```sh
swift test
./script/build_and_run.sh --build-only
./script/install_ime.sh
```

After installation, select `Mistype` → `Zhuyin` from the macOS input-source
menu. Type with the normal Zhuyin keyboard: tones are optional and continuous
typing converts as you go (only the syllable still being typed stays in
Bopomofo); tone keys finish syllables and Space is the first tone. Return
commits exactly what is shown, unfinished Bopomofo included (注音文 works); Shift+Return sends the keys as typed Bopomofo. Down/Tab (or Left to walk back to a word) enter
selection mode, where the home-row keys `asdfghjk` pick from the panel
(configurable in Preferences; they type Zhuyin outside the mode) and Escape
leaves the mode; outside it Escape cancels the composition. Shift+digit and
Shift+= [ ] ` type full-width symbols (！＠＃＄％︿＆＊（）＋｛｝～). Picks are
learned locally per word, and single characters in the context of the
word before them. Backspace edits the raw composition; Shift (tap) or
Shift-Space commits and toggles 中/英.

The diagnostic path exercises the packaged dictionary without an IME client:

```sh
dist/MistypeIME.app/Contents/MacOS/MistypeIME --decode su3cl3
```

The installer keeps the previous bundle at `.cache/MistypeIME-previous.app`
when replacing an existing Mistype installation. Disable the source with
`swift run -c release MistypeSourceTool disable` if needed.

### Releases

Pushing a `v*` tag runs `.github/workflows/release.yml`, which tests, builds a
universal (arm64 + x86_64) bundle via `script/package_release.sh`, and
publishes `Mistype-<version>.dmg` to GitHub Releases. The same script runs
locally (`./script/package_release.sh 0.2.0`). Users drag `MistypeIME.app`
onto the `Input Methods` link in the DMG (`/Library/Input Methods`, admin
password required), then log out/in or add it under System Settings →
Keyboard → Input Sources.

Signing is optional and driven by repository secrets:

| Secret | Purpose |
| --- | --- |
| `MACOS_CERT_P12_BASE64`, `MACOS_CERT_PASSWORD` | Developer ID Application certificate (`.p12`, base64) |
| `NOTARY_KEY_P8_BASE64`, `NOTARY_KEY_ID`, `NOTARY_ISSUER_ID` | App Store Connect API key for `notarytool` |

Without them the DMG is ad-hoc signed and Gatekeeper blocks it on other
machines; run `xattr -dr com.apple.quarantine "/Library/Input Methods/MistypeIME.app"`
after installing. A self-signed certificate does not avoid this; only a
Developer ID signature plus notarization does.

## License

MIT (see `LICENSE`). The bundled dictionary data comes from McBopomofo (MIT)
and libtabe (BSD-style); see `THIRD_PARTY_NOTICES.md`.
