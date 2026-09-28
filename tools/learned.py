"""List what the IME has learned (local user phrase store, read-only).

Word entries are "readings -> text" (boosted anywhere those readings
occur); context entries are "previous word | readings -> text" (boosted
only right after that word). Bonus is what decode adds: +6 on the first
pick, +1 per repeat, capped at +10.

The store is sensitive local data: this only prints it to your terminal.

Usage:
  python tools/learned.py [path]   # default: the IME's store
"""

import json
import sys
from pathlib import Path

DEFAULT = Path.home() / "Library/Application Support/Mistype/user_phrases.json"


def bonus(count: int) -> float:
    return min(6.0 + (count - 1) * 1.0, 10.0)


def rows(store: dict) -> tuple[list[tuple], list[tuple]]:
    words, contexts = [], []
    for key, texts in store.get("entries", {}).items():
        for text, record in texts.items():
            count = int(record.get("count", 1))
            if "|" in key:
                previous, readings = key.split("|", 1)
                contexts.append((previous, readings, text, count, bonus(count)))
            else:
                words.append((key, text, count, bonus(count)))
    words.sort(key=lambda row: (-row[2], row[0]))
    contexts.sort(key=lambda row: (-row[3], row[0]))
    return words, contexts


def main(argv: list[str]) -> int:
    path = Path(argv[1]) if len(argv) > 1 else DEFAULT
    if not path.exists():
        print(f"no learned phrases yet ({path})")
        return 0
    store = json.loads(path.read_text(encoding="utf-8"))
    if store.get("version") != 2:
        print(f"store version {store.get('version')} is ignored by the IME (expects 2)")
        return 0
    words, contexts = rows(store)
    print(f"{path}\n{len(words)} word entries, {len(contexts)} context entries (cap 500)")
    if words:
        print("\nwords (readings -> text)")
        for readings, text, count, gain in words:
            print(f"  {readings:20} -> {text:10} x{count}  +{gain:g}")
    if contexts:
        print("\ncontext (after word | readings -> text)")
        for previous, readings, text, count, gain in contexts:
            print(f"  {previous:8} | {readings:12} -> {text:6} x{count}  +{gain:g}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
