"""tools/keylog_calibrate.py on a synthetic key log (no personal data)."""
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "tools"))
import keylog_calibrate as kc  # noqa: E402

CODE = {label: code for code, label in kc.KEYCODES.items()}


def log(*compositions: str) -> list[str]:
    """One log line per key; `<` is Backspace, `!` Return, `v` keeps its key."""
    lines, ts = [], 1_760_000_000.0
    for keys in compositions:
        comp = 0
        for ch in keys:
            label = {"<": "⌫", "!": "⏎", "_": "↓"}.get(ch, ch)
            lines.append(f"{ts:.3f} key={CODE[label]} flags=0 en=0 latin=0 comp={comp} sel=0 n=0 cur=-1 seg=0")
            ts += 0.1
            comp = 0 if label == "⏎" else 1
    return lines


class KeylogCalibrateTest(unittest.TestCase):
    def kinds(self, *compositions: str) -> dict:
        return kc.calibrate(log(*compositions))["fix_kinds"]

    def test_clean_toned_and_toneless(self):
        result = kc.calibrate(log("su3cl3!", "sucl!"))  # 你好 toned, then toneless
        self.assertEqual(result["syllables"], 4)
        self.assertEqual(result["tone_rate"], 0.5)
        self.assertEqual(result["noticed_slip_rate"], 0)

    def test_neighbour_substitution(self):
        self.assertEqual(self.kinds("su3vl<<cl3!"), {"substitution-neighbour": 1})

    def test_far_substitution(self):
        self.assertEqual(self.kinds("su3pl<<cl3!"), {"substitution-far": 1})

    def test_transposition(self):
        self.assertEqual(self.kinds("us<<su3!"), {"transposition": 1})

    def test_omission_and_insertion(self):
        self.assertEqual(self.kinds("s3<<su3!"), {"omission": 1})
        self.assertEqual(self.kinds("suu3<<<u3!"), {"insertion": 1})

    def test_tone_change(self):
        self.assertEqual(self.kinds("su4<3!"), {"tone": 1})

    def test_english_and_chords_ignored(self):
        lines = log("su3!")
        lines.append("1760000100.000 key=0 flags=0 en=1 latin=0 comp=0 sel=0 n=0 cur=-1 seg=0")
        lines.append(f"1760000101.000 key=0 flags={1 << 20} en=0 latin=0 comp=0 sel=0 n=0 cur=-1 seg=0")
        self.assertEqual(kc.calibrate(lines)["keys"], 3)

    def test_old_format_without_english_fields(self):
        lines = [line.replace(" en=0 latin=0", "") for line in log("su3!")]
        self.assertEqual(kc.calibrate(lines)["syllables"], 1)

    def test_picks_counted(self):
        self.assertEqual(kc.calibrate(log("su3__!"))["picks_per_composition"], 2.0)


if __name__ == "__main__":
    unittest.main()
