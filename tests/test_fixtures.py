import json
import unittest
from pathlib import Path

from mistype.decoder import OfflineDecoder
from mistype.models import RawEvent
from mistype.normalize import normalize_events

FIXTURES = Path(__file__).parent / "fixtures"

# Every offline phrase must be reachable through the real key path, so a
# table entry can never silently rot the way combined finals once did.
PHRASE_SEQUENCES = {
    "你好": ["BPMF:s", "BPMF:u", "BPMF:3", "BPMF:c", "BPMF:l", "BPMF:3"],
    "你": ["BPMF:s", "BPMF:u", "BPMF:3"],
    "你好嗎": ["BPMF:s", "BPMF:u", "BPMF:3", "BPMF:c", "BPMF:l", "BPMF:3",
             "BPMF:a", "BPMF:8", "BPMF:SPACE"],
    "我是學生": ["BPMF:j", "BPMF:i", "BPMF:3", "BPMF:g", "BPMF:4",
              "BPMF:v", "BPMF:m", "BPMF:,", "BPMF:6", "BPMF:g", "BPMF:/"],
    "這是有趣的實驗": ["BPMF:5", "BPMF:k", "BPMF:4", "BPMF:g", "BPMF:4",
                   "BPMF:u", "BPMF:.", "BPMF:3", "BPMF:f", "BPMF:m", "BPMF:4",
                   "BPMF:2", "BPMF:k", "BPMF:SPACE", "BPMF:g", "BPMF:6",
                   "BPMF:u", "BPMF:0", "BPMF:4"],
    "謝謝": ["BPMF:v", "BPMF:u", "BPMF:,", "BPMF:4",
            "BPMF:v", "BPMF:u", "BPMF:,", "BPMF:SPACE"],
    "對不起": ["BPMF:2", "BPMF:j", "BPMF:o", "BPMF:4", "BPMF:1", "BPMF:j",
             "BPMF:4", "BPMF:f", "BPMF:u", "BPMF:3"],
    "好的嗎": ["BPMF:c", "BPMF:l", "BPMF:3", "BPMF:2", "BPMF:k", "BPMF:SPACE",
             "BPMF:a", "BPMF:8", "BPMF:SPACE"],
    "早上好": ["BPMF:y", "BPMF:l", "BPMF:3", "BPMF:g", "BPMF:;",
             "BPMF:4", "BPMF:c", "BPMF:l", "BPMF:3"],
}


def decode_codes(codes):
    events = [RawEvent("test", i, i * 90_000_000, "left", "key", code)
              for i, code in enumerate(codes)]
    return OfflineDecoder().decode(normalize_events(events))


class FixtureTests(unittest.TestCase):
    def test_every_phrase_is_reachable_from_physical_keys(self):
        self.assertEqual(set(PHRASE_SEQUENCES), set(OfflineDecoder.phrases.values()))
        for expected, codes in PHRASE_SEQUENCES.items():
            with self.subTest(phrase=expected):
                result = decode_codes(codes)
                self.assertEqual(result.text, expected)
                self.assertEqual(result.decoder_id, "offline-fixture")

    def test_manifest_fixtures_replay_deterministically(self):
        manifest = json.loads((FIXTURES / "manifest.json").read_text(encoding="utf-8"))
        self.assertTrue(manifest["expected_text"])
        for filename, expected in manifest["expected_text"].items():
            with self.subTest(fixture=filename):
                events = [RawEvent.from_dict(json.loads(line))
                          for line in (FIXTURES / filename).read_text(encoding="utf-8").splitlines()
                          if line.strip()]
                first = OfflineDecoder().decode(normalize_events(events))
                second = OfflineDecoder().decode(normalize_events(events))
                self.assertEqual(first.text, expected)
                self.assertEqual(second.text, expected)
                self.assertEqual(first.decoder_id, "offline-fixture")


if __name__ == "__main__":
    unittest.main()
