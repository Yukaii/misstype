"""Small, grouped parameter-selection experiment through the real Session.

Uses Chinese dev sentences only; all personas/seeds of one sentence stay
in one fold. The nine profiles are fixed before looking at results. This
is a stability diagnostic on previously seen development material, NOT a
new blind test, and never edits product defaults or the typing baseline.

  python3 tools/calibrate_decoder.py --out .cache/decoder-calibration/report.json
  python3 tools/calibrate_decoder.py --out .cache/decoder-calibration/report.json --resume

Requires a ReleaseFast misstype-dev. Profiles run sequentially for comparable
per-key latency. Saved profile results are synthetic, local and replayable.
"""

import argparse
import hashlib
import json
import os
import subprocess
import time
from dataclasses import asdict, replace
from pathlib import Path

import typing_eval as typing

DEFAULT = "w0.50-c1.00"
PROFILES = {
    f"w{word:.2f}-c{context:.2f}": (word, context)
    for word in (0.25, 0.5, 0.75) for context in (0.75, 1.0, 1.25)
}
ENV_KEYS = (
    "MISSTYPE_WORD_PENALTY", "MISSTYPE_HOMOPHONE_WEIGHT",
    "MISSTYPE_TONELESS_HOMOPHONE_WEIGHT", "MISSTYPE_TONELESS_SEGMENT_WEIGHT",
    "MISSTYPE_NO_HOMOPHONE", "MISSTYPE_LEARN_ACROSS_SPLITS", "MISSTYPE_NO_TONE_RUN_SPLITS",
    "MISSTYPE_REPAIR_REQUIRES_NO_CLEAN",
)


def distance(profile: str) -> float:
    word, context = PROFILES[profile]
    return abs(word - 0.5) + abs(context - 1.0)


def sentence_fold(sentence: str, folds: int) -> int:
    return int.from_bytes(hashlib.sha256(sentence.encode()).digest()[:8], "big") % folds


def aggregate(rows: dict, ids: list[str], cases: dict) -> dict:
    reached = [i for i in ids if rows[i]["reached"]]
    chars = sum(len(cases[i].expected) for i in reached)
    picks = sum(rows[i]["picks"] for i in reached)
    return {
        "n": len(ids), "exact": sum(rows[i]["exact"] for i in ids),
        "unreached": len(ids) - len(reached), "picks": picks,
        "picks_100_reached": round(100 * picks / max(chars, 1), 3),
    }


def changes(rows: dict, baseline: dict, ids: list[str]) -> dict:
    return {
        "fewer": [i for i in ids if typing.cost(rows[i]) < typing.cost(baseline[i])],
        "more": [i for i in ids if typing.cost(rows[i]) > typing.cost(baseline[i])],
    }


def eligible(rows: dict, baseline: dict, ids: list[str], cases: dict) -> bool:
    # A gain among survivors must not conceal newly uncorrectable sentences.
    # Guard each persona separately; also protect all typo-free controls.
    for persona in {cases[i].persona for i in ids}:
        members = [i for i in ids if cases[i].persona == persona]
        new = aggregate(rows, members, cases)
        old = aggregate(baseline, members, cases)
        if new["unreached"] > old["unreached"]:
            return False
        if persona.startswith("clean") and new["exact"] < old["exact"]:
            return False
    return True


def select(results: dict, ids: list[str], cases: dict) -> str:
    baseline = results[DEFAULT]
    def objective(profile: str) -> tuple:
        metrics = aggregate(results[profile], ids, cases)
        return (metrics["unreached"], metrics["picks"],
                len(changes(results[profile], baseline, ids)["more"]), distance(profile), profile)
    candidates = [p for p in results if eligible(results[p], baseline, ids, cases)]
    return min(candidates, key=objective)


def grouped_evaluation(results: dict, cases: dict, folds: int) -> dict:
    ids = list(cases)
    assignments = {i: sentence_fold(cases[i].expected, folds) for i in ids}
    selected, details = {}, []
    for fold in range(folds):
        train = [i for i in ids if assignments[i] != fold]
        test = [i for i in ids if assignments[i] == fold]
        if not train or not test:
            raise ValueError("empty fold; use fewer folds or more independent sentences")
        profile = select(results, train, cases)
        delta = changes(results[profile], results[DEFAULT], test)
        for i in test:
            selected[i] = results[profile][i]
        details.append({
            "fold": fold, "profile": profile,
            "train_sentences": len({cases[i].expected for i in train}),
            "test_sentences": len({cases[i].expected for i in test}),
            "fewer": len(delta["fewer"]), "more": len(delta["more"]),
        })
    delta = changes(selected, results[DEFAULT], ids)
    return {
        "folds": details, "baseline": aggregate(results[DEFAULT], ids, cases),
        "selected": aggregate(selected, ids, cases),
        "by_persona": {
            p: {"baseline": aggregate(results[DEFAULT], members, cases),
                "selected": aggregate(selected, members, cases)}
            for p in sorted({c.persona for c in cases.values()})
            for members in [[i for i in ids if cases[i].persona == p]]
        },
        "fewer": delta["fewer"], "more": delta["more"],
        "guards_hold": eligible(selected, results[DEFAULT], ids, cases),
    }


def sha(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def run_profile(binary: Path, resources: Path, profile: str, cases: list) -> tuple[dict, dict]:
    word, context = PROFILES[profile]
    env = {k: v for k, v in os.environ.items() if k not in ENV_KEYS}
    env.update({
        "MISSTYPE_WORD_PENALTY": str(word), "MISSTYPE_HOMOPHONE_WEIGHT": str(context),
        "MISSTYPE_TONELESS_HOMOPHONE_WEIGHT": str(context),
        "MISSTYPE_TONELESS_SEGMENT_WEIGHT": str(0.4 * context),
    })
    # No --carry: sentence selection must not accidentally train later cases.
    command = [str(binary), "--resources", str(resources), "--session-batch", "-", "--show"]
    stdin = "".join(f"{c.keys}\t{c.expected}\n" for c in cases)
    output = subprocess.run(command, input=stdin, capture_output=True, text=True,
                            env=env, check=True, timeout=1800).stdout.splitlines()
    if len(output) != len(cases):
        raise RuntimeError(f"{profile}: {len(output)} outputs for {len(cases)} cases")
    current = [replace(c, result=json.loads(line)) for c, line in zip(cases, output)]
    return typing.score(current)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bin", type=Path, default=typing.APP_BIN)
    parser.add_argument("--resources", type=Path,
                        default=typing.ROOT / "dist/MisstypeIME.app/Contents/Resources")
    parser.add_argument("--seeds", type=int, default=2)
    parser.add_argument("--folds", type=int, default=5)
    parser.add_argument("--out", type=Path, default=typing.ROOT / ".cache/decoder-calibration/report.json")
    parser.add_argument("--resume", action="store_true", help="reuse only fingerprint-matching profiles")
    args = parser.parse_args()
    if args.seeds < 1 or args.folds < 2:
        parser.error("seeds must be positive and folds at least 2")
    binary, resources = args.bin.resolve(), args.resources.resolve()
    mode = subprocess.run([str(binary), "--build-mode"], capture_output=True,
                          text=True, check=True).stdout.strip()
    if mode not in ("fast", "ReleaseFast"):
        parser.error("build misstype-dev with -Doptimize=ReleaseFast first")
    corpus = typing.build_cases(["dev"], args.seeds, [])
    cases = {c.id: c for c in corpus}
    if len(cases) != len(corpus):
        raise ValueError("duplicate case IDs")
    fingerprint = {
        "version": 1, "binary_sha256": sha(binary), "seeds": args.seeds,
        "typing_eval_sha256": sha(Path(typing.__file__)),
        "calibration_sha256": sha(Path(__file__)), "corpus_sha256": sha(typing.CORPUS),
        "input_keys_sha256": hashlib.sha256("".join(
            f"{c.id}\t{c.keys}\n" for c in corpus).encode()).hexdigest(),
        "personas": [asdict(p) for p in typing.PERSONAS],
        "resources": {name: sha(resources / name) for name in
                      ("lexicon.tsv", "toneless.tsv", "local_phrases.tsv", "homophone.bin")},
    }
    results, summaries = {}, {}
    cache_dir = args.out.parent / "profiles"
    cache_dir.mkdir(parents=True, exist_ok=True)
    for profile in sorted(PROFILES, key=lambda p: (distance(p), p)):
        started = time.perf_counter()
        path = cache_dir / f"{profile}.json"
        saved = json.loads(path.read_text()) if args.resume and path.exists() else None
        if saved and saved["fingerprint"] == fingerprint:
            summary, rows = saved["summary"], saved["cases"]
            if set(rows) != set(cases) or any(rows[i]["keys"] != c.keys for i, c in cases.items()):
                raise ValueError("cached keys/cases differ from this run")
            reused = True
        else:
            summary, rows = run_profile(binary, resources, profile, corpus)
            path.write_text(json.dumps({"fingerprint": fingerprint, "summary": summary,
                                        "cases": rows}, ensure_ascii=False) + "\n")
            reused = False
        results[profile], summaries[profile] = rows, summary
        metrics = aggregate(rows, list(cases), cases)
        print(f"{profile}: exact={metrics['exact']} unreachable={metrics['unreached']} "
              f"picks={metrics['picks']} {time.perf_counter() - started:.1f}s "
              f"{'cached' if reused else 'measured'}", flush=True)
    evaluation = grouped_evaluation(results, cases, args.folds)
    candidate = select(results, list(cases), cases)
    profile_metrics = {}
    for profile, rows in results.items():
        delta = changes(rows, results[DEFAULT], list(cases))
        profile_metrics[profile] = {
            **aggregate(rows, list(cases), cases), "fewer": len(delta["fewer"]),
            "more": len(delta["more"]), "guards_hold": eligible(rows, results[DEFAULT], list(cases), cases),
            "latency": {p: summaries[profile][f"zh | {p}"]["ms_p95"]
                        for p in ("clean", "clean-toneless", "clean-partial-tones", "partial-tones")},
        }
    report = {
        "meta": {"commit": typing.git_commit(), "fingerprint": fingerprint,
                 "set": "dev", "folds": args.folds, "blind_test": False,
                 "profiles": PROFILES, "baseline_profile": DEFAULT},
        "profiles": profile_metrics, "grouped_selection": evaluation,
        "all_dev_candidate": candidate,
        "eligible_for_new_blind_test": bool(evaluation["fewer"]) and not evaluation["more"]
                                      and evaluation["guards_hold"],
    }
    args.out.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
    print(json.dumps({k: evaluation[k] for k in ("folds", "baseline", "selected", "guards_hold")},
                     ensure_ascii=False, indent=2))
    print(f"out-of-fold fewer={len(evaluation['fewer'])} more={len(evaluation['more'])}; "
          f"new blind test gate={report['eligible_for_new_blind_test']}; saved {args.out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
