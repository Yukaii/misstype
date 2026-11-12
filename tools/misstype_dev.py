"""Shared access to the Zig core for the measurement tools.

Replaces the retired Python prototype (src/misstype): key maps, the touch
layout and decoding all come from `misstype-dev` (core-zig/src/dev.zig), so
the tools measure the implementation that ships rather than a second one.

Build first: `cd core-zig && zig build` (or -Doptimize=ReleaseFast for
latency). Override the binary with $MISSTYPE_DEV, the lexicon directory
with $MISSTYPE_RESOURCES (default: the built app bundle's Resources).

JSONL traces (tests/fixtures/*.jsonl) keep the raw evidence format of the
capture layer: one RawEvent per line, `kind` key or touch_down, `code` like
`BPMF:s`, `LATIN:AI`, `SPACE`, touch payloads with normalized `x`/`y`.
`trace_input` turns one into what the Zig session consumes.
"""
from __future__ import annotations

import functools
import json
import os
import subprocess
from collections.abc import Mapping
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
BIN = Path(os.environ.get("MISSTYPE_DEV", ROOT / "core-zig/zig-out/bin/misstype-dev"))
os.environ.setdefault("MISSTYPE_RESOURCES", str(ROOT / "dist/MisstypeIME.app/Contents/Resources"))

TONE_KEYS = frozenset("3467")
# ASCII punctuation typed with Shift on a Zhuyin keyboard; Chinese mode
# produces the full-width form.
FULL_WIDTH = {"!": "！", "?": "？", ":": "：", ",": "，", ".": "。"}


def run(*args: str, stdin: str | None = None) -> str:
    if not BIN.exists():
        raise FileNotFoundError(f"{BIN} not built; run `cd core-zig && zig build`")
    return subprocess.run([str(BIN), *args], input=stdin, capture_output=True,
                          text=True, check=True).stdout


@functools.cache
def keymap() -> dict[str, str]:
    """Physical key -> Zhuyin symbol or tone mark (Dachen layout)."""
    return dict(line.split("\t", 1) for line in run("--keymap").splitlines())


@functools.cache
def zhuyin_to_key() -> dict[str, str]:
    return {symbol: key for key, symbol in keymap().items()}


class _Lazy(Mapping):
    """A mapping filled from misstype-dev on first use, so importing a tool
    never needs the binary (tests of pure helpers run without a build)."""

    def __init__(self, load):
        self._load = load

    def __getitem__(self, key):
        return self._load()[key]

    def __iter__(self):
        return iter(self._load())

    def __len__(self):
        return len(self._load())


ZHUYIN_TO_KEY: Mapping[str, str] = _Lazy(zhuyin_to_key)


@functools.cache
def touch_layout() -> tuple[str, dict[str, tuple[str, float, float]]]:
    """(layout version, key -> (surface 'l'|'r', x, y)) of the touch surfaces."""
    lines = run("--touch-layout").splitlines()
    version = lines[0].split("\t")[1]
    keys = {}
    for line in lines[1:]:
        key, surface, x, y = line.split("\t")
        keys[key] = (surface, float(x), float(y))
    return version, keys


def format_taps(taps: list[tuple[str, float, float]]) -> str:
    return " ".join(f"{s}:{x:.6f},{y:.6f}" for s, x, y in taps)


def touch_batch(taps: list[list[tuple[str, float, float]]], *flags: str,
                top: int = 1) -> list[list[tuple[str, float, str, float]]]:
    """Decode many tap sequences with one lexicon load.

    Returns per sequence a list of (text, score, keys, spatial_cost)."""
    out = run("--touch-batch", "-", "--top", str(top), *flags,
              stdin="".join(format_taps(t) + "\n" for t in taps))
    answers: list[list[tuple[str, float, str, float]]] = [[]]
    for line in out.split("\n")[:-1]:
        if not line:
            answers.append([])
            continue
        text, score, keys, cost = line.split("\t")
        answers[-1].append((text, float(score), keys, float(cost)))
    return answers[:len(taps)]


def load_trace(path: str | Path) -> list[dict]:
    with open(path, encoding="utf-8") as handle:
        return [json.loads(line) for line in handle if line.strip()]


def trace_input(events: list[dict]) -> tuple[str, str | list[tuple[str, float, float]]]:
    """('keys', session-trace keys) or ('touch', taps) for a JSONL trace.

    Key traces: `BPMF:x` is key x; `LATIN:` text is typed as is (ASCII
    punctuation as its full-width Chinese-mode form); `SPACE` is the Space
    key, except right after a tone or at the start, where the prototype used
    it only as a separator and the IME would read it as an extra space."""
    if all(e["kind"] == "touch_down" for e in events):
        taps = [("l" if e["surface"] == "left" else "r", e["payload"]["x"], e["payload"]["y"])
                for e in events]
        return "touch", taps
    keys: list[str] = []
    for e in events:
        if e["kind"] != "key":
            raise ValueError(f"mixed key/touch trace: {e['kind']}")
        code = e["code"]
        if code in ("SPACE", "BPMF:SPACE"):
            if keys and keys[-1] not in TONE_KEYS:
                keys.append(" ")
        elif code.startswith("BPMF:"):
            keys.append(code[5:])
        elif code.startswith("LATIN:"):
            keys.extend(FULL_WIDTH.get(c, c) for c in code[6:])
        else:
            raise ValueError(f"unknown key code {code}")
    return "keys", "".join(keys)


def replay_trace(events: list[dict]) -> str:
    """Final committed text of a trace through the real Zig session/decoder."""
    kind, data = trace_input(events)
    if kind == "touch":
        answers = touch_batch([data])[0]
        return answers[0][0] if answers else ""
    finals = [line.split("\t", 1)[1] for line in run("--session-trace", data).splitlines()
              if line.startswith("final\t")]
    return finals[-1] if finals else ""
