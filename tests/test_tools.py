import contextlib
import importlib.util
import io
import json
import tempfile
import unittest
from pathlib import Path

TOOLS = Path(__file__).parent.parent / "tools"


def load_tool(name):
    spec = importlib.util.spec_from_file_location(name, TOOLS / f"{name}.py")
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


bench = load_tool("bench")
replay = load_tool("replay")
noise = load_tool("noise")
lm_rescore = load_tool("lm_rescore")
lm_choose = load_tool("lm_choose")


class ToolTests(unittest.TestCase):
    def test_cer_counts_character_edits(self):
        self.assertEqual(bench.cer("你好", "你好"), 0.0)
        self.assertAlmostEqual(bench.cer("你好", "你"), 0.5)
        self.assertEqual(bench.cer("", ""), 0.0)
        self.assertEqual(bench.cer("", "你"), 1.0)
        self.assertEqual(bench.levenshtein("kitten", "sitting"), 3)

    def test_group_of_splits_keyboard_and_touch_paths(self):
        self.assertEqual(bench.group_of("keyboard-ni.jsonl"), "keyboard")
        self.assertEqual(bench.group_of("touch-ni-hao.jsonl"), "touch")
        self.assertEqual(bench.group_of("notes.txt"), "other")

    def test_replay_summarizes_a_trace(self):
        summary = replay.summarize(Path(__file__).parent / "fixtures" / "touch-ni-hao.jsonl")
        self.assertEqual(summary["text"], "你好")
        self.assertEqual(summary["decoder"], "offline-fixture")
        self.assertEqual(summary["alignment"], [["ㄋ ㄧˇ ㄏ ㄠˇ", "你好"]])

    def test_bench_passes_on_the_fixed_fixture_set(self):
        with contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(bench.main(["--repeats", "3"]), 0)

    def test_noise_is_deterministic_per_seed(self):
        first = noise.jitter_trace(["s", "u", "3"], 0.10, seed=7)
        second = noise.jitter_trace(["s", "u", "3"], 0.10, seed=7)
        third = noise.jitter_trace(["s", "u", "3"], 0.10, seed=8)
        self.assertEqual(
            [(event.code, event.payload["x"], event.payload["y"]) for event in first],
            [(event.code, event.payload["x"], event.payload["y"]) for event in second])
        self.assertNotEqual(
            [(event.payload["x"], event.payload["y"]) for event in first],
            [(event.payload["x"], event.payload["y"]) for event in third])

    def test_noise_radius_zero_taps_key_centers(self):
        events = noise.jitter_trace(["s", "u", "3"], 0.0, seed=1)
        self.assertEqual([event.code for event in events],
                         ["BPMF_FUZZY:s", "BPMF_FUZZY:u", "BPMF:3"])

    def test_noise_clamps_to_the_surface(self):
        for event in noise.jitter_trace(["s", "y", "-"], 0.6, seed=3):
            if event.payload:
                self.assertTrue(0 <= event.payload["x"] <= 1)
                self.assertTrue(0 <= event.payload["y"] <= 1)

    def test_sweep_ablation_never_beats_fuzziness(self):
        rows = noise.sweep(noise.PROBES, [0.0, 0.10, 0.20], seeds=8)
        self.assertEqual(len(rows), len(noise.PROBES) * 3)
        for row in rows:
            with self.subTest(probe=row["probe"], radius=row["radius"]):
                self.assertLessEqual(row["ablated_match"], row["fuzzy_match"])
                if row["radius"] == 0.0:
                    self.assertEqual(row["fuzzy_match"], 1.0)

    def test_parse_evidence_keeps_tones_attached(self):
        bases = {"ㄋㄧ", "ㄏㄠ", "ㄗㄠ", "ㄕㄤ"}
        evidence = lm_rescore.parse_evidence("su3cl4", bases)
        self.assertEqual(evidence, [
            {"base": "ㄋㄧ", "tone": "ˇ", "tone_key": "3"},
            {"base": "ㄏㄠ", "tone": "ˋ", "tone_key": "4"},
        ])

    def test_jev_state_keeps_raw_input_and_candidate_provenance(self):
        state = json.loads(lm_choose.build_jev_state(
            "su3cl4",
            [{"base": "ㄋㄧ", "tone": "ˇ", "tone_key": "3"}],
            ["你好", "泥好"],
            [{"rank": 1, "score": -1.0, "repairs": 0, "unresolved": 0},
             {"rank": 2, "score": -2.0, "repairs": 1, "unresolved": 0}],
            user_context="開場問候",
        ))
        self.assertEqual(state["phonetic_input"]["raw_keys"], "su3cl4")
        self.assertEqual(state["phonetic_input"]["syllables"][0]["tone"], "ˇ")
        self.assertEqual(state["candidates"][1]["repairs"], 1)
        self.assertEqual(state["user_context"], "開場問候")

    def test_jev_rich_state_exposes_alignment_and_contract(self):
        state = json.loads(lm_choose.build_jev_state(
            "su3",
            [{"base": "ㄋㄧ", "tone": "ˇ", "tone_key": "3"}],
            ["你", "泥"],
            [{"rank": 1, "score": -1.0}, {"rank": 2, "score": -2.0}],
            char_bases={"你": {"ㄋㄧ"}, "泥": {"ㄋㄧ"}},
            rich_context=True,
        ))
        self.assertTrue(state["decoder_contract"]["candidate_rank_is_offline_provenance"])
        self.assertTrue(state["candidates"][0]["phonetic_alignment"]["length_match"])
        self.assertTrue(state["candidates"][1]["phonetic_alignment"]["characters"][0]["base_match"])
        self.assertEqual(state["candidates"][1]["diff_from_candidate_1"],
                         [{"position": 1, "offline": "你", "candidate": "泥"}])

    def test_user_preferences_are_scoped_to_matching_readings(self):
        payload = {
            "version": 1,
            "entries": {
                "ㄋㄧㄏㄠ": {
                    "妳好": {"count": 2, "updatedAt": 123.0},
                    "你好": {"count": 1, "updatedAt": 456.0},
                },
                "ㄅㄚ": {"吧": {"count": 99, "updatedAt": 789.0}},
            },
        }
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "phrases.json"
            path.write_text(json.dumps(payload, ensure_ascii=False))
            preferences = lm_choose.load_user_preferences(path, [
                {"base": "ㄋㄧ", "tone": None, "tone_key": None},
                {"base": "ㄏㄠ", "tone": None, "tone_key": None},
            ])
            malformed = Path(directory) / "malformed.json"
            malformed.write_text(json.dumps({"entries": []}))
            malformed_preferences = lm_choose.load_user_preferences(malformed, [])
        self.assertEqual(preferences, [
            {"text": "妳好", "count": 2},
            {"text": "你好", "count": 1},
        ])
        self.assertEqual(malformed_preferences, [])

    def test_prompt_variants_are_explicit_and_distinct(self):
        prompts = {
            name: lm_choose.phonetic_instructions(name)
            for name in lm_choose.PROMPT_VARIANTS
        }
        self.assertEqual(set(prompts), {"structured", "constraints", "contrastive", "rich-audit"})
        self.assertEqual(len(set(prompts.values())), 4)
        with self.assertRaises(ValueError):
            lm_choose.phonetic_instructions("missing")


if __name__ == "__main__":
    unittest.main()
