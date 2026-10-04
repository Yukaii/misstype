import argparse
import json
import sys

from .decoder import OfflineDecoder
from .models import RawEvent
from .normalize import normalize_events


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Replay a Misstype JSONL trace")
    parser.add_argument("trace", nargs="?", help="JSONL trace file, or stdin")
    args = parser.parse_args(argv)
    source = open(args.trace, encoding="utf-8") if args.trace else sys.stdin
    try:
        events = [RawEvent.from_dict(json.loads(line)) for line in source if line.strip()]
    finally:
        if args.trace:
            source.close()
    tokens = normalize_events(events)
    result = OfflineDecoder().decode(tokens)
    print(json.dumps({"text": result.text, "decoder": result.decoder_id,
                      "latency_ms": result.latency_ms, "tokens": [token.__dict__ for token in tokens]},
                     ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
