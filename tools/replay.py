"""Deterministic single-trace replay shared by manual checks and bench.

Usage:
    PYTHONPATH=src python tools/replay.py <trace.jsonl>

Prints one JSON summary line: decoded text, token alignment, confidence,
decoder provenance, and latency. No network, no model, no side effects.
"""

import json
import sys
from pathlib import Path

from mistype.decoder import OfflineDecoder
from mistype.models import DecodeResult, PhoneticToken, RawEvent
from mistype.normalize import normalize_events


def load_events(path: str | Path) -> list[RawEvent]:
    """Load a JSONL trace; every line is one RawEvent dict."""
    events = []
    with open(path, encoding="utf-8") as handle:
        for line in handle:
            if line.strip():
                events.append(RawEvent.from_dict(json.loads(line)))
    return events


def run(events: list[RawEvent], revision: int = 0) -> tuple[DecodeResult, list[PhoneticToken]]:
    """Replay events through normalization and offline decoding."""
    tokens = normalize_events(events)
    return OfflineDecoder().decode(tokens, revision=revision), tokens


def summarize(path: str | Path) -> dict:
    """Replay a trace file and return a JSON-serializable summary."""
    result, tokens = run(load_events(path))
    return {
        "trace": str(path),
        "text": result.text,
        "confidence": result.confidence,
        "decoder": result.decoder_id,
        "decoder_version": result.decoder_version,
        "latency_ms": result.latency_ms,
        "alignment": [list(pair) for pair in result.alignment],
        "tokens": len(tokens),
    }


def main(argv: list[str] | None = None) -> int:
    args = argv if argv is not None else sys.argv[1:]
    if len(args) != 1:
        print("usage: PYTHONPATH=src python tools/replay.py <trace.jsonl>",
              file=sys.stderr)
        return 2
    print(json.dumps(summarize(args[0]), ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
