# Contributing

Misstype is an experimental input device and decoder. Read
[`docs/project-outline.md`](docs/project-outline.md) and
[`docs/architecture.md`](docs/architecture.md) before changing behavior, and
[`AGENTS.md`](AGENTS.md) for the working loop, privacy rules and canonical
commands. Review capacity is limited; meeting these requirements does not
guarantee a review or merge.

## Ground rules

- **One PR, one problem.** Independent fixes go in separate PRs, whatever the
  diff size.
- **Discuss big changes first.** For a large feature or a change to
  user-visible behavior, open an issue or discussion before investing the
  work, and link it from the PR. Small fixes and focused improvements can go
  straight to a PR. (We may require prior approval later if contributor volume
  grows.)
- **Show evidence.** Explain how you established the problem, how you checked
  the fix, and what you saw. "Tests pass" is not evidence by itself.
  - Bugs: a replayable reproduction (key sequence for `misstype-dev
    --session-trace`, a `--decode` input, or a fixture).
  - Decoder changes: candidates before/after, quality, latency, and whether
    the result is offline or LLM-assisted.
  - UI changes: before/after screenshots; a short recording when timing,
    motion or interaction matters. Upload them to the PR. Never commit
    PR-only assets.
- **Keep it private.** Raw traces and typed text are sensitive. Fixtures must
  be synthetic or redacted. No API keys, caches or build artifacts.
- **Cross-platform.** A core behavior change is not done until the Linux
  fcitx5 conformance scenarios (C1–C15, `docs/cross-platform.md`) still pass,
  and golden files are regenerated and reviewed when output intentionally
  changes (`docs/zig-port.md`).

## Checks

Run the fastest relevant check for your layer, then what CI will run for it:

| Layer | Command |
| --- | --- |
| Zig core | `cd core-zig && "$(../script/zig/bootstrap.sh)" build test` |
| Golden gates | `core-zig/bench/compare.sh && core-zig/bench/parity.sh && core-zig/bench/replay.sh` |
| macOS UI types | `swift test` (after `./script/zig/build_macos.sh`) |
| Linux | `script/linux/dev.sh 'bash script/linux/test_all.sh'` |
| wasm | `node tests/wasm_test.mjs` after `zig build wasm` |
| Python prototype | `PYTHONPATH=src python -m unittest discover -s tests -v` |

Say in the PR what you could not run.

## Pull requests

Use the PR template. Titles are conventional commits in plain language
(`fix(core): ...`, `feat(touch): ...`). Write the description yourself: problem,
change, scope, verification.

## AI-assisted contributions

AI assistance is welcome and held to the same bar as any other change.

- Disclose it in the PR's **AI assistance** section: model and harness (for
  example "Claude Sonnet 5.5 via Claude Code").
- A human is accountable for every line, runs the verification, and answers
  review comments personally.
- Agents open a PR only when their human asks. No unattended or bulk PRs.
- Agent-specific instructions live in [`AGENTS.md`](AGENTS.md#pull-requests).
