"""Jev success-rate report from the IME file trace.

Acceptance proxy, not correctness: the gate fires only on untouched states
(no pins/picks), so the committed text for the SAME raw keys is the ground
truth for that evaluation. A user override after the fact grades 0 — that is
still a non-accept, which is what this measures.

Reads ~/Library/Logs/MistypeIME-debug.log (or a path argument) and prints:
  requests (starts), ok / stale / err, flip rate,
  grades, accept rate overall, accept rate on flips,
  mean confidence of accepts vs rejects, skip-code breakdown.

Line shapes parsed (booleans/numbers only — the trace never carries the
graded texts by policy):
  [jev-api] start ...
  [jev-api] ok ms=.. pick=.. conf=0.92 flip=1
  [jev-api] stale ... / [jev-api] err ...
  jev-grade accept=1 flip=0 conf=0.92
  jev skip=short | jev skip=decisive
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

DEFAULT_LOG = Path.home() / "Library/Logs/MistypeIME-debug.log"

START = re.compile(r"\[jev-api\] start ")
OK = re.compile(r"\[jev-api\] ok ms=\d+ms pick=\d+:.* conf=([0-9.]+) flip=([01])")
STALE = re.compile(r"\[jev-api\] stale ")
ERR = re.compile(r"\[jev-api\] err ")
GRADE = re.compile(r"jev-grade accept=([01]) flip=([01]) conf=([0-9.]+)")
SKIP = re.compile(r"jev skip=(\w+)")


def summarize(lines):
    """Pure aggregation over trace lines (testable without a log file)."""
    starts = oks = stales = errs = 0
    flips = 0
    grades = accepts = flip_grades = flip_accepts = 0
    conf_accept: list[float] = []
    conf_reject: list[float] = []
    skips: dict[str, int] = {}
    for line in lines:
        if START.search(line):
            starts += 1
            continue
        ok_match = OK.search(line)
        if ok_match:
            oks += 1
            if ok_match.group(2) == "1":
                flips += 1
            continue
        if STALE.search(line):
            stales += 1
            continue
        if ERR.search(line):
            errs += 1
            continue
        match = GRADE.search(line)
        if match:
            accept, flip, conf = match.group(1) == "1", match.group(2), float(match.group(3))
            grades += 1
            accepts += accept
            (conf_accept if accept else conf_reject).append(conf)
            if flip == "1":
                flip_grades += 1
                flip_accepts += accept
        skip = SKIP.search(line)
        if skip:
            skips[skip.group(1)] = skips.get(skip.group(1), 0) + 1
    def mean(values):
        return sum(values) / len(values) if values else float("nan")
    return {
        "starts": starts,
        "ok": oks,
        "stale": stales,
        "err": errs,
        "flips": flips,
        "flip_rate": flips / oks if oks else float("nan"),
        "grades": grades,
        "accept_rate": accepts / grades if grades else float("nan"),
        "flip_accept_rate": flip_accepts / flip_grades if flip_grades else float("nan"),
        "mean_conf_accept": mean(conf_accept),
        "mean_conf_reject": mean(conf_reject),
        "skips": skips,
    }


def report(summary):
    """Render the aggregation for humans."""
    rows = [
        f"requests={summary['starts']} ok={summary['ok']} "
        f"stale={summary['stale']} err={summary['err']}",
        f"flips={summary['flips']} flip_rate={summary['flip_rate']:.2f}",
        f"grades={summary['grades']} accept_rate={summary['accept_rate']:.2f} "
        f"flip_accept_rate={summary['flip_accept_rate']:.2f}",
        f"mean_conf accept={summary['mean_conf_accept']:.2f} "
        f"reject={summary['mean_conf_reject']:.2f}",
        "skips=" + (", ".join(f"{k}:{v}" for k, v in sorted(summary["skips"].items())) or "-"),
    ]
    return "\n".join(rows)


def main(argv=None):
    path = Path(argv[1]) if argv and len(argv) > 1 else DEFAULT_LOG
    try:
        lines = path.read_text(encoding="utf-8", errors="replace").splitlines()
    except OSError as error:
        print(f"cannot read {path}: {error}", file=sys.stderr)
        return 2
    print(report(summarize(lines)))
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
