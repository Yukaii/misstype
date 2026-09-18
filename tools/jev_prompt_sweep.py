"""Small, explicit Jev prompt sweep with synthetic contextual holdouts.

The ordinary ``lm_choose.py`` cases intentionally contain no semantic
context, so prompt changes cannot legitimately recover a homophone choice.
This tool adds held-out contexts that describe the user's intent without
including the full expected Chinese answer. It includes a generic context,
an explicit action-versus-size context, a clean greeting control, and a
synthetic learned preference. A variant is useful only if it improves the
in-beam tie without worsening the clean control and remains stable.

Usage (remote calls are explicit and synthetic only)::

    PYTHONPATH=src python tools/jev_prompt_sweep.py
    PYTHONPATH=src python tools/jev_prompt_sweep.py --reps 3 \
        --variant constraints --variant contrastive
    PYTHONPATH=src python tools/jev_prompt_sweep.py --reps 3 \
        --rich-context --variant rich-audit
"""

from __future__ import annotations

import argparse
import os
import statistics
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "tools"))

from lm_choose import PROMPT_VARIANTS, jev_choose, load_dotenv  # noqa: E402
from lm_rescore import (cer, load_toneless_bases, offline_entries,
                        load_char_bases, parse_evidence)  # noqa: E402


CASES = [
    {
        "name": "dada-context",
        "keys": "hkguvu8cjo1jcjo282jo",
        "expected": "測試一下會不會打對",
        "context": "我在測試輸入法能不能把我輸入的文字正確顯示出來。",
    },
    {
        "name": "dada-intent-context",
        "keys": "hkguvu8cjo1jcjo282jo",
        "expected": "測試一下會不會打對",
        # This is still synthetic context, not the expected answer: it names
        # the intended action/result distinction that the generic holdout
        # leaves implicit.
        "context": "這是輸入法測試：我想問它能不能把這句話打正確；"
                   "末尾要表達輸入這個動作和正確的結果，不是描述大小。",
    },
    {
        "name": "nihao-context",
        "keys": "su3cl3",
        "expected": "你好",
        "context": "這是聊天開頭，我想向對方問好。",
    },
    {
        "name": "dada-learned-preference",
        "keys": "hkguvu8cjo1jcjo282jo",
        "expected": "測試一下會不會打對",
        "context": "",
        # Synthetic local-learning signal. It is deliberately explicit: this
        # case tests whether Jev can honor a preference once supplied, not
        # whether it can invent one from fluency.
        "user_preferences": [{"text": "測試一下會不會打對", "count": 1}],
    },
]


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Jev prompt sweep")
    parser.add_argument("--reps", type=int, default=3)
    parser.add_argument("--topn", type=int, default=8)
    parser.add_argument("--timeout", type=float, default=120.0)
    parser.add_argument("--gateway-model", default="typesafe-ai/jev")
    parser.add_argument(
        "--rich-context", action="store_true",
        help="include character-level phonetic alignment and decoder contract",
    )
    parser.add_argument("--variant", action="append", choices=sorted(PROMPT_VARIANTS),
                        dest="variants", help="prompt variant (repeatable)")
    args = parser.parse_args(argv)
    api_key = (os.environ.get("AI_GATEWAY_API_KEY", "")
               or load_dotenv(ROOT / ".env").get("AI_GATEWAY_API_KEY", ""))
    if not api_key:
        print("refusing to run: AI_GATEWAY_API_KEY absent "
              "(environment or .env; never commit it)")
        return 2

    # Keep the historical three-way sweep as the default. The richer audit
    # prompt is an explicit arm so old measurements remain comparable.
    variants = args.variants or ["structured", "constraints", "contrastive"]
    toneless_bases = load_toneless_bases()
    char_bases = load_char_bases() if args.rich_context else None
    totals = {variant: {"flips": 0, "worsens": 0, "same": 0,
                        "abstains": 0, "calls": 0}
              for variant in variants}
    for case in CASES:
        entries, decode_ms = offline_entries(case["keys"], limit=args.topn)
        candidates = [str(entry["text"]) for entry in entries]
        if not candidates:
            print(f"--- {case['name']} [no offline candidates]")
            continue
        evidence = parse_evidence(case["keys"], toneless_bases)
        expected_rank = (candidates.index(case["expected"]) + 1
                         if case["expected"] in candidates else None)
        baseline = cer(candidates[0], case["expected"])
        print(f"--- {case['name']} recall={'yes' if expected_rank else 'no'} "
              f"rank={expected_rank or '-'} baseline_cer={baseline:.3f} "
              f"decode_ms={decode_ms:.0f}")
        for variant in variants:
            picks: list[int | None] = []
            latencies: list[float] = []
            confidences: list[float | None] = []
            for _ in range(args.reps):
                pick, elapsed, confidence = jev_choose(
                    candidates, evidence, args.gateway_model, api_key,
                    args.timeout, raw_keys=case["keys"], metadata=entries,
                    user_context=case["context"],
                    user_preferences=case.get("user_preferences", []),
                    prompt_variant=variant,
                    char_bases=char_bases,
                    rich_context=args.rich_context)
                picks.append(pick)
                latencies.append(elapsed)
                confidences.append(confidence)
                totals[variant]["calls"] += 1
                if pick is None:
                    totals[variant]["abstains"] += 1
                else:
                    after = cer(candidates[pick], case["expected"])
                    if after < baseline:
                        totals[variant]["flips"] += 1
                    elif after > baseline:
                        totals[variant]["worsens"] += 1
                    else:
                        totals[variant]["same"] += 1
            rendered = [candidates[pick] if pick is not None else "<abstain>"
                        for pick in picks]
            print(f"  {variant}: picks={[(pick + 1 if pick is not None else None) for pick in picks]} "
                  f"texts={rendered} conf={confidences} "
                  f"p50_ms={statistics.median(latencies):.0f}")
    print("--- aggregate")
    for variant in variants:
        print(f"{variant}: {totals[variant]}")
    return 0 if all(item["worsens"] == 0 for item in totals.values()) else 1


if __name__ == "__main__":
    raise SystemExit(main())
