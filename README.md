# Mistype

Mistype is an experiment in low-interference text capture: two split touch surfaces (initially simulated in software) let a user type from muscle memory without stopping to aim at precise keys or choose Chinese candidates. A phonetic trace is captured first, then reconstructed into Chinese, English, or mixed text after a pause or explicit commit.

The first target is Bopomofo (Zhuyin), with English mixing and a local decoder. The project begins as a software prototype so that interaction, decoding quality, and latency can be measured before designing hardware.

## Documents

- [Project outline](docs/project-outline.md): product intent, milestones, experiments, and success criteria.
- [Technical architecture](docs/architecture.md): layers, event contracts, decoding pipeline, and deployment choices.
- [Development guide](AGENTS.md): working loop, privacy rules, and definition of done.

The design takes inspiration from [Qingjian](https://github.com/qingjian-team/qingjian), especially its platform-independent core and delayed whole-phrase reconstruction. Mistype is a separate experiment; compatibility with Qingjian is a milestone, not a promise.

## Run the M0 replay

The first slice uses Python 3.11+ and has no runtime dependencies:

```sh
PYTHONPATH=src python -m unittest discover -s tests -v
PYTHONPATH=src python -m mistype.cli examples/hello.jsonl
PYTHONPATH=src python -m mistype.cli examples/keyboard-ni.jsonl
PYTHONPATH=src python -m mistype.cli examples/touch-ni-hao.jsonl
```

The fixture format is JSONL so traces can be recorded, redacted, diffed, and replayed independently of the eventual UI or hardware. Replayable phrase fixtures (touch + keyboard, with expected text in `manifest.json`) live under `tests/fixtures/`.

The touch prototype is a versioned full-split mapper (`LAYOUT_VERSION = "full-split-1"` in `mistype.touch`): `nearest_key(surface, x, y)` accepts normalized coordinates and returns a replayable hypothesis, `layout_keys`/`key_position` expose the layout for rendering and tests, and tone-key touches emit exact codes so the normalizer can attach the tone.

For a complete simulator path, use `mistype.touch_session.TouchSession`, which exposes `touch`, `preview`, and `commit` while keeping event sequencing and normalization internal.

The eventual macOS version will be an InputMethodKit adapter around this core. System-wide IME integration is intentionally an M5 milestone; the simulator and replay pipeline run earlier on macOS without installing an input method.
