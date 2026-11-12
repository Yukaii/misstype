"""Replay one JSONL trace through the Zig core and print a JSON summary.

Usage:
    python3 tools/replay.py <trace.jsonl>

Key traces run through the real `Session` (`misstype-dev --session-trace`),
touch traces through the lattice touch decoder (`misstype-dev --touch`).
See tools/misstype_dev.py for the trace format and key translation. Needs a
built misstype-dev (`cd core-zig && zig build`). Offline only.
"""

import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import misstype_dev as dev  # noqa: E402


def summarize(path: str | Path) -> dict:
    """Replay a trace file and return a JSON-serializable summary."""
    events = dev.load_trace(path)
    kind, data = dev.trace_input(events)
    return {
        "trace": str(path),
        "path": kind,
        "input": data if kind == "keys" else dev.format_taps(data),
        "events": len(events),
        "text": dev.replay_trace(events),
    }


def main(argv: list[str] | None = None) -> int:
    args = argv if argv is not None else sys.argv[1:]
    if len(args) != 1:
        print("usage: python3 tools/replay.py <trace.jsonl>", file=sys.stderr)
        return 2
    print(json.dumps(summarize(args[0]), ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
