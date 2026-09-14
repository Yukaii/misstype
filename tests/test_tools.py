import contextlib
import importlib.util
import io
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


if __name__ == "__main__":
    unittest.main()
