#!/usr/bin/env python3
"""Every L("…") key used by the IME must exist in each Localizable.strings,
and no language may carry keys the source no longer uses.

    python3 tools/check_localizations.py
"""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
STRING = r'"((?:[^"\\]|\\.)*)"'

def used_keys(source="MistypeIME"):
    keys = set()
    for path in (ROOT / "Sources" / source).glob("*.swift"):
        for match in re.finditer(r'\bL\(\s*' + STRING, path.read_text()):
            keys.add(match.group(1).replace('\\"', '"'))
    keys.discard("")
    return keys

def strings_keys(path):
    return {m.group(1).replace('\\"', '"')
            for m in re.finditer(r'^' + STRING + r'\s*=', path.read_text(), re.M)}

def main():
    failed = False
    # The IME and the DMG installer each ship their own string tables.
    tables = [(used_keys("MistypeIME"), (ROOT / "Resources").glob("*.lproj/Localizable.strings")),
              (used_keys("MistypeInstaller"), (ROOT / "Resources" / "Installer").glob("*.lproj/Localizable.strings"))]
    for used, paths in tables:
        failed |= check(used, paths)
    print("localizations OK" if not failed else "localizations FAILED")
    return 1 if failed else 0

def check(used, paths):
    failed = False
    for path in sorted(paths):
        have = strings_keys(path)
        for label, keys in (("missing", used - have), ("unused", have - used)):
            for key in sorted(keys):
                print(f"{path.parent.name}: {label}: {key!r}")
                failed = True
    return failed

if __name__ == "__main__":
    sys.exit(main())
