#!/usr/bin/env python3
"""Flag repository paths in Markdown that no longer exist.

Docs cite files as `code/spans`; when code moves (the Swift core retired, the
Python prototype removed) those citations rot silently and send the next
reader, human or agent, looking for files that are gone. This checks every
code span that starts with a top-level repository directory against
`git ls-files`.

Not flagged:
- paths git ignores (generated output such as site/dist, site/public);
- paths with globs or placeholders (`*`, `<`, `{`);
- files listed in HISTORY_DOCS, which record what was true at the time;
- paths under EXTERNAL_PREFIXES, which name files in other projects or on
  the published website;
- paths that exist relative to the doc's own directory (video/README.md
  citing `src/timeline.ts`).

Usage: python3 tools/check_doc_paths.py [file.md ...]   (default: all tracked .md)
Exit 1 when a stale path is found.
"""
from __future__ import annotations

import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

# Dated logs: they describe past code on purpose.
HISTORY_DOCS = {
    "docs/lab-notebook.md",
    "docs/zig-port.md",
}
# Paths inside other projects that the survey docs cite.
EXTERNAL_PREFIXES = (
    "src/rime/",
    "src/conversion/",
    "src/enable.js",
    "src/keymap.ts",
    # Licence copies under the published website's root, not this repository
    # (THIRD_PARTY_NOTICES.md, "website copy").
    "third_party/Hairline/LICENSE",
    "third_party/browser_wasi_shim/",
    "third_party/Vite/",
)
TOP_LEVEL = (
    "core-zig", "Sources", "script", "tools", "tests", "docs", "linux", "site",
    "src", "packages", "Resources", "third_party", "video", ".github",
)
SPAN = re.compile(r"`((?:%s)/[A-Za-z0-9_./-]+)`" % "|".join(re.escape(t) for t in TOP_LEVEL))


def git(*args: str) -> list[str]:
    out = subprocess.run(["git", *args], cwd=ROOT, check=True, capture_output=True, text=True)
    return out.stdout.splitlines()


def main(argv: list[str]) -> int:
    tracked = set(git("ls-files"))
    dirs = {str(Path(f).parent) for f in tracked}
    dirs |= {p for d in list(dirs) for p in (str(x) for x in Path(d).parents)}
    docs = argv or [f for f in tracked if f.endswith(".md")]
    candidates: list[tuple[str, int, str]] = []
    for doc in docs:
        if doc in HISTORY_DOCS:
            continue
        text = (ROOT / doc).read_text(encoding="utf-8", errors="replace")
        for lineno, line in enumerate(text.splitlines(), 1):
            for match in SPAN.finditer(line):
                path = match.group(1).rstrip("/.").split("#")[0]
                if any(c in path for c in "*<{") or path.startswith(EXTERNAL_PREFIXES):
                    continue
                local = str(Path(doc).parent / path)
                if not {path, local} & (tracked | dirs):
                    candidates.append((doc, lineno, path))
    if not candidates:
        return 0
    # One git call for all candidates: ignored paths are generated output.
    ignored = set(subprocess.run(
        ["git", "check-ignore", "--no-index", "--stdin"], cwd=ROOT, text=True,
        input="\n".join(p for _, _, p in candidates), capture_output=True,
    ).stdout.splitlines())
    stale = [(d, n, p) for d, n, p in candidates if p not in ignored]
    for doc, lineno, path in stale:
        print(f"{doc}:{lineno}: `{path}` does not exist")
    if stale:
        print(f"{len(stale)} stale path(s). Fix the reference, or add the doc to "
              "HISTORY_DOCS if it is a dated log.", file=sys.stderr)
    return 1 if stale else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
