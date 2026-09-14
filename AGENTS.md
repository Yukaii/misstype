# Development guide

This repository is an experimental input device and decoder. The current goal is to validate the interaction model before committing to custom hardware.

## Product constraints

- Capture first, decode later. The input path must not force candidate selection or correction while the user is composing.
- Keep the raw trace. Rendered Chinese is a reconstruction and must never replace the original touch/key/phonetic evidence.
- Chinese input is phonetic-first. Bopomofo (Zhuyin) is a first-class mode; English and mixed Chinese/English text are also required.
- Offline behavior is the baseline. A local deterministic decoder should remain useful when no model, network, or API key is available.
- Do not add hardware dependencies until the touchscreen prototype demonstrates a measurable benefit over a conventional keyboard.

## Working loop

1. Read `docs/project-outline.md` and `docs/architecture.md` before changing behavior.
2. Write down the hypothesis and the smallest experiment that can falsify it.
3. Keep changes in one layer where possible: capture, phonetic normalization, decoding, or platform adapter.
4. Preserve replayable fixtures. Every bug found from an input trace should become a fixture without storing unnecessary personal text.
5. Run the fastest relevant checks after each change, then the full test suite before merging.
6. For decoder changes, report latency, candidate quality, and whether the result came from offline or LLM-assisted decoding.
7. Update the architecture or decision record when a boundary, data contract, or user-visible behavior changes.

## Data and privacy

- Treat raw traces and typed text as sensitive local data.
- Do not send input to a remote service by default. Remote LLM use must be explicit, replaceable, and clearly observable in development logs.
- Use synthetic or redacted fixtures in the repository.
- Do not commit API keys, personal traces, generated model caches, or build artifacts.

## Definition of done

A change is ready when its behavior is covered by a replayable test or documented manual check, the relevant command has passed, and the docs describe any new assumption or limitation. Prefer small reversible changes over speculative abstractions.

## Canonical commands

The M0 implementation uses Python 3.11+ with no runtime dependencies:

```sh
PYTHONPATH=src python -m unittest discover -s tests -v
PYTHONPATH=src python -m mistype.cli examples/hello.jsonl
```

Use scripts under `tools/` for deterministic replay and measurement rather than ad-hoc notebooks. Keep these commands runnable from the repository root when the implementation language changes.
