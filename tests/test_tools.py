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
jev_success = load_tool("jev_success")
cursor_replay = load_tool("cursor_replay")
learned = load_tool("learned")
_spec = importlib.util.spec_from_file_location(
    "prepare_lexicon", TOOLS.parent / "script" / "prepare_lexicon.py")
assert _spec is not None and _spec.loader is not None
prepare_lexicon = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(prepare_lexicon)


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

    def test_jev_choice_job_numbers_criteria_by_offline_rank(self):
        job = lm_choose.jev_choice_job(
            ["你好", "泥好"], [{"base": "ㄋㄧ", "tone": "ˇ", "tone_key": "3"}],
            "multilingual", raw_keys="su3cl4")
        pick = job["questions"]["pick"]
        self.assertEqual(pick["type"], "choice")
        self.assertEqual(pick["criteria"], {"1": "你好", "2": "泥好"})
        self.assertEqual(json.loads(job["state"])["phonetic_input"]["raw_keys"], "su3cl4")

    def test_choice_answer_abstains_outside_candidate_list(self):
        with contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(lm_choose.parse_choice_answer(
                {"choice": "2", "probabilities": {"1": 0.3, "2": 0.7}}, 2), (1, 0.7))
            self.assertEqual(lm_choose.parse_choice_answer(
                {"choice": "9", "probabilities": {"9": 1.0}}, 2), (None, 1.0))
            self.assertEqual(lm_choose.parse_choice_answer(
                {"choice": "你好"}, 2), (None, None))

    def test_local_jev_url_must_be_loopback(self):
        self.assertTrue(lm_choose.is_loopback_url("http://127.0.0.1:8000/v1/systemone"))
        self.assertTrue(lm_choose.is_loopback_url("http://localhost:8001/predict"))
        self.assertFalse(lm_choose.is_loopback_url("https://ai-gateway.vercel.sh/v4"))
        self.assertFalse(lm_choose.is_loopback_url("http://127.0.0.1.example.com/"))

    def test_cursor_replay_encodes_both_typing_styles(self):
        self.assertEqual(cursor_replay.encode("ㄋㄧˇ ㄏㄠˇ ㄇㄚ˙", toned=True), "su3cl3a87")
        self.assertEqual(cursor_replay.encode("ㄊㄚ ㄕㄨㄛ", toned=True), "w8 gji ")
        self.assertEqual(cursor_replay.encode("ㄋㄧˇ ㄏㄠˇ", toned=False), "sucl")
        for _, readings in cursor_replay.SEED:
            cursor_replay.encode(readings, toned=True)  # every symbol maps

    def test_cursor_replay_reads_sentences_from_lexicon_words(self):
        reverse = {"一下": ("ㄧ ㄒㄧㄚˋ", -8.5), "一": ("ㄧ", -4.0),
                   "下": ("ㄒㄧㄚˋ", -5.0), "了": ("ㄌㄜ˙", -5.3)}
        self.assertEqual(cursor_replay.readings_for("一下了", reverse), "ㄧ ㄒㄧㄚˋ ㄌㄜ˙")
        with self.assertRaises(ValueError):
            cursor_replay.readings_for("一X", reverse)
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "lexicon.tsv"
            path.write_text("ㄌㄜ˙\t了\t-5.3\nㄌㄧㄠˇ\t了\t-5.3\nㄧ-ㄒㄧㄚˋ\t一下\t-8.5\n",
                            encoding="utf-8")
            reverse = cursor_replay.load_reverse_lexicon(path)
        self.assertEqual(reverse["了"][0], "ㄌㄜ˙")
        self.assertEqual(reverse["一下"][0], "ㄧ ㄒㄧㄚˋ")

    def test_learned_splits_word_and_context_entries(self):
        store = {"version": 2, "entries": {
            "ㄉㄚㄉㄨㄟ": {"打對": {"count": 2, "updatedAt": 0}},
            "下次|ㄗㄞ": {"再": {"count": 9, "updatedAt": 0}}}}
        words, contexts = learned.rows(store)
        self.assertEqual(words, [("ㄉㄚㄉㄨㄟ", "打對", 2, 7.0)])
        self.assertEqual(contexts, [("下次", "ㄗㄞ", "再", 9, 10.0)])

    def test_cursor_replay_parses_binary_output(self):
        stdout = ("entries=1 user=0\n大對\t-7.0\trepairs=0 unresolved=0\n"
                  "replay aligned picks=- ranks=\n"
                  "replay startAtCursor picks=1 ranks=0 learned=ㄉㄚㄉㄨㄟ=打對\n")
        outcomes = cursor_replay.parse_replay(stdout)
        self.assertEqual(outcomes["aligned"],
                         {"picks": None, "ranks": [], "learned": [], "top1": "大對"})
        self.assertEqual(outcomes["startAtCursor"]["picks"], 1)
        self.assertEqual(outcomes["startAtCursor"]["ranks"], [0])
        self.assertEqual(outcomes["startAtCursor"]["learned"], ["ㄉㄚㄉㄨㄟ=打對"])

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

    def test_jev_success_grades_acceptance_without_text(self):
        lines = [
            "1789702306.9 [jev-api] start model=x cands=8 ctxChars=0",
            "1789702307.0 [jev-api] ok ms=200ms pick=1:xxx conf=0.96 flip=0",
            "1789702307.1 [jev-api] stale ms=150ms (superseded)",
            "1789702307.2 [jev-api] err ms=1200ms boom",
            "1789702307.3 [jev-api] ok ms=200ms pick=2:yyy conf=0.70 flip=1",
            "1789702308.0 jev-grade accept=1 flip=0 conf=0.96",
            "1789702308.1 jev-grade accept=0 flip=1 conf=0.70",
            "1789702308.2 jev skip=short",
            "1789702308.3 jev skip=decisive",
        ]
        summary = jev_success.summarize(lines)
        self.assertEqual(summary["starts"], 1)
        self.assertEqual(summary["ok"], 2)
        self.assertEqual(summary["stale"], 1)
        self.assertEqual(summary["err"], 1)
        self.assertEqual(summary["flips"], 1)
        self.assertAlmostEqual(summary["flip_rate"], 0.5)
        self.assertEqual(summary["grades"], 2)
        self.assertAlmostEqual(summary["accept_rate"], 0.5)
        self.assertAlmostEqual(summary["flip_accept_rate"], 0.0)
        self.assertAlmostEqual(summary["mean_conf_accept"], 0.96)
        self.assertAlmostEqual(summary["mean_conf_reject"], 0.70)
        self.assertEqual(summary["skips"], {"short": 1, "decisive": 1})
        rendered = jev_success.report(summary)
        self.assertIn("accept_rate=0.50", rendered)
        self.assertNotIn("xxx", rendered + "yyy")

    def test_heterophone_secondary_readings_drop(self):
        # 暫: ㄓㄢˋ is heterophony1; the unlisted variant ㄗㄢˋ must not keep
        # the char's full count (it outranked 讚 for ㄗㄢˋ).
        floor = prepare_lexicon.HETEROPHONE_FLOOR
        self.assertEqual(prepare_lexicon.heterophone_score(-9.5, 1), -9.5)
        self.assertEqual(prepare_lexicon.heterophone_score(-9.5, None), floor)
        self.assertAlmostEqual(prepare_lexicon.heterophone_score(-9.5, 2),
                               -9.5 - prepare_lexicon.HETEROPHONE_STEP)
        self.assertEqual(prepare_lexicon.heterophone_score(-15.0, 3), floor)


if __name__ == "__main__":
    unittest.main()
