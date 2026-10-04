# Development, build and release

Developer-facing content moved out of the README. For user-facing install and usage see the [README](../README-en.md); for the working loop and privacy rules see [AGENTS.md](../AGENTS.md).

## macOS IME (build and install)

The macOS IME is a SwiftPM InputMethodKit bundle. It pulls in a pinned, checksum-verified McBopomofo-derived dictionary at build time.

```sh
swift test
./script/build_and_run.sh --build-only
./script/install_ime.sh
```

To exercise the packaged dictionary without an IME client:

```sh
dist/MisstypeIME.app/Contents/MacOS/MisstypeIME --decode su3cl3
```

The installer keeps the previous bundle at `.cache/MisstypeIME-previous.app` when replacing an installation. To disable the input source:

```sh
swift run -c release MisstypeSourceTool disable
```

## Releases

Pushing a `v*` tag runs `.github/workflows/release.yml`, which tests, builds a universal (`arm64` + `x86_64`) bundle via `script/package_release.sh`, and publishes `Misstype-<version>.dmg` to GitHub Releases. The script also runs locally (`./script/package_release.sh 0.2.0`).

Signing is optional and driven by repository secrets:

| Secret | Purpose |
| --- | --- |
| `MACOS_CERT_P12_BASE64`, `MACOS_CERT_PASSWORD` | Developer ID Application certificate (`.p12`, base64) |
| `NOTARY_KEY_P8_BASE64`, `NOTARY_KEY_ID`, `NOTARY_ISSUER_ID` | App Store Connect API key for `notarytool` |

Without them the DMG is ad-hoc signed and Gatekeeper blocks it on other machines; run `xattr -dr com.apple.quarantine "/Library/Input Methods/MisstypeIME.app"` after installing. A self-signed certificate does not avoid this; only Developer ID plus notarization does.

For the DMG installer, Sparkle updates and verification status see [Packaging, installer and updates](release.md).

## Linux (fcitx5)

```sh
# Build and run the headless suite in the Docker dev container
script/linux/dev.sh 'script/linux/build.sh && script/linux/test_fcitx5.sh'

# All layers (core tests, C ABI, fcitx5 headless suite)
script/linux/dev.sh 'bash script/linux/test_all.sh'
```

See [Linux port](linux-port.md) and [Cross-platform contract](cross-platform.md).

## Python prototype

The initial slice (Python 3.11+, no runtime dependencies) explores coordinate-based touch input. Decoding behavior lives in the Swift `MisstypeCore` package; do not port decoder changes to Python.

```sh
PYTHONPATH=src python -m unittest discover -s tests -v
PYTHONPATH=src python -m misstype.cli examples/hello.jsonl
PYTHONPATH=src python -m misstype.cli examples/keyboard-ni.jsonl
PYTHONPATH=src python -m misstype.cli examples/touch-ni-hao.jsonl
PYTHONPATH=src python tools/bench.py
```

Traces are JSONL so they can be recorded, redacted, diffed and replayed independently of the UI or hardware. Replayable phrase fixtures live in `tests/fixtures/`.
