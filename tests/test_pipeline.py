import unittest

from mistype.decoder import OfflineDecoder
from mistype.models import RawEvent
from mistype.normalize import normalize_events
from mistype.session import SessionCoordinator
from mistype.touch import nearest_key, touch_event


class PipelineTests(unittest.TestCase):
    def events(self, *codes):
        return [RawEvent("test", i, i, "left" if i % 2 else "right", "key", code) for i, code in enumerate(codes)]

    def test_replay_decodes_zhuyin_phrase(self):
        tokens = normalize_events(self.events("ZH:ㄋ", "ZH:ㄧˇ", "SPACE", "ZH:ㄏ", "ZH:ㄠˇ"))
        result = OfflineDecoder().decode(tokens, revision=3)
        self.assertEqual(result.text, "你好")
        self.assertEqual(result.revision, 3)
        self.assertEqual(result.decoder_id, "offline-fixture")

    def test_mixed_latin_is_preserved(self):
        tokens = normalize_events(self.events("ZH:ㄋ", "ZH:ㄧˇ", "SPACE", "LATIN:AI", "LATIN:!"))
        self.assertEqual(OfflineDecoder().decode(tokens).text, "你AI!")

    def test_unknown_phrase_is_replayable(self):
        tokens = normalize_events(self.events("ZH:ㄅ", "ZH:ㄚ"))
        self.assertEqual(OfflineDecoder().decode(tokens).text, "[ㄅ ㄚ]")

    def test_physical_zhuyin_keys_are_normalized_with_tone(self):
        tokens = normalize_events(self.events("BPMF:s", "BPMF:u", "BPMF:3"))
        self.assertEqual([token.value for token in tokens], ["ㄋ", "ㄧ"])
        self.assertEqual(tokens[-1].tone, "ˇ")

    def test_session_commits_after_pause_and_keeps_revision(self):
        session = SessionCoordinator(pause_ms=100)
        for event in self.events("BPMF:s", "BPMF:u", "BPMF:3"):
            session.ingest(event)
        self.assertIsNone(session.maybe_commit(50_000_000))
        result = session.maybe_commit(101_000_000)
        self.assertIsNotNone(result)
        self.assertEqual(result.text, "你")
        self.assertEqual(session.committed_text, "你")
        self.assertEqual(session.preview().text, "")

    def test_session_rejects_non_monotonic_events(self):
        session = SessionCoordinator()
        session.ingest(self.events("BPMF:s")[0])
        with self.assertRaises(ValueError):
            session.ingest(RawEvent("test", 2, -1, "left", "key", "BPMF:u"))

    def test_fuzzy_key_keeps_alternatives(self):
        tokens = normalize_events(self.events("BPMF_FUZZY:s", "BPMF:u", "BPMF:3"))
        self.assertEqual(tokens[0].value, "ㄋ")
        self.assertTrue(tokens[0].alternatives)

    def test_fuzzy_phrase_uses_context_to_correct_typo(self):
        tokens = normalize_events(self.events("BPMF_FUZZY:d", "BPMF:u", "BPMF:3"))
        self.assertEqual(OfflineDecoder().decode(tokens).text, "你")

    def test_touch_surface_maps_coordinates_to_nearest_key(self):
        hypothesis = nearest_key("left", 0.30, 0.50)
        self.assertEqual(hypothesis.key, "a")
        self.assertTrue(hypothesis.alternatives)

    def test_touch_rejects_out_of_range_coordinates(self):
        with self.assertRaises(ValueError):
            nearest_key("right", 1.1, 0.5)

    def test_touch_event_replays_through_normalizer(self):
        event = touch_event("touch", 0, 0, "left", 0.30, 0.50)
        tokens = normalize_events([event])
        self.assertEqual(tokens[0].kind, "zhuyin")
        self.assertEqual(tokens[0].value, "ㄇ")


if __name__ == "__main__":
    unittest.main()
