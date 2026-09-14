import unittest

from mistype.decoder import OfflineDecoder
from mistype.models import RawEvent
from mistype.normalize import normalize_events


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


if __name__ == "__main__":
    unittest.main()
