import sys
import json
import os
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tools"))
import calibrate_decoder as calibration
from typing_eval import Case


class CalibrationTests(unittest.TestCase):
    def test_calibration_is_not_silently_changed_by_the_shell_repair_gate(self):
        case = Case("one", "zh", "daily", "clean", "dev", 0, "你好", "su3cl3", False)
        result = {"before_fix": "你好", "final": "你好", "picks": 0,
                  "fix_keys": 0, "views": [], "ms": [0.1]}
        with patch.dict(os.environ, {"MISSTYPE_REPAIR_REQUIRES_NO_CLEAN": "1"}):
            with patch.object(calibration.subprocess, "run",
                              return_value=SimpleNamespace(stdout=json.dumps(result) + "\n")) as run:
                calibration.run_profile(Path("binary"), Path("resources"), calibration.DEFAULT, [case])
            self.assertNotIn("MISSTYPE_REPAIR_REQUIRES_NO_CLEAN", run.call_args.kwargs["env"])
            self.assertEqual(os.environ["MISSTYPE_REPAIR_REQUIRES_NO_CLEAN"], "1")

    def test_sentence_variants_never_cross_selection_and_validation(self):
        cases = {}
        for sentence in ("你好", "明天見", "一起吃飯", "回家休息", "今天下雨", "帶雨傘"):
            for persona in ("clean", "clean-toneless", "partial-tones"):
                for seed in range(2):
                    key = f"{sentence}|{persona}|{seed}"
                    cases[key] = Case(key, "zh", "daily", persona, "dev", seed, sentence, "keys", False)
        rows = {i: {"exact": False, "reached": True, "picks": 1} for i in cases}
        results = {p: dict(rows) for p in calibration.PROFILES}
        for profile, favored_fold in (("w0.25-c1.00", 0), ("w0.75-c1.00", 1)):
            results[profile] = {
                i: {"exact": calibration.sentence_fold(c.expected, 2) == favored_fold,
                    "reached": True,
                    "picks": 0 if calibration.sentence_fold(c.expected, 2) == favored_fold else 2}
                for i, c in cases.items()
            }
        report = calibration.grouped_evaluation(results, cases, 2)
        # Each profile helps one fold and harms the other. Correct grouping
        # picks the winner on training sentences and exposes damage on the
        # unseen fold, instead of leaking variants into parameter selection.
        self.assertEqual(sum(f["test_sentences"] for f in report["folds"]), 6)
        for fold in report["folds"]:
            self.assertEqual(fold["profile"], "w0.75-c1.00" if fold["fold"] == 0 else "w0.25-c1.00")
        self.assertEqual(set(report["more"]), set(cases))
        tied = {p: dict(rows) for p in calibration.PROFILES}
        self.assertEqual(calibration.select(tied, list(cases), cases), calibration.DEFAULT)

    def test_fewer_picks_cannot_hide_lost_coverage_or_damage_to_a_control(self):
        cases = {
            "clean": Case("clean", "zh", "daily", "clean", "dev", 0, "你好", "su3cl3", False),
            "noisy": Case("noisy", "zh", "daily", "partial-tones", "dev", 0, "你好", "sucl3", False),
        }
        baseline = {
            "clean": {"exact": True, "reached": True, "picks": 0},
            "noisy": {"exact": False, "reached": True, "picks": 2},
        }
        results = {
            calibration.DEFAULT: baseline,
            "w0.25-c1.00": {"clean": baseline["clean"],
                            "noisy": {"exact": False, "reached": False, "picks": 0}},
            "w0.75-c1.00": {"clean": {"exact": False, "reached": True, "picks": 1},
                            "noisy": {"exact": True, "reached": True, "picks": 0}},
        }
        self.assertEqual(calibration.select(results, list(cases), cases), calibration.DEFAULT)


if __name__ == "__main__":
    unittest.main()
