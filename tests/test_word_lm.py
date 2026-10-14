"""Binary builder invariants independent of the Zig probability tests."""
from collections import Counter
from pathlib import Path
import struct
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'tools'))
import word_lm


class WordModelTests(unittest.TestCase):
    def test_complete_counts_and_determinism(self):
        uni = Counter({'你': 1, '妳': 9, word_lm.EOS: 10})
        pairs = Counter({(word_lm.BOS, '你'): 1, (word_lm.BOS, '妳'): 9,
                         ('你', word_lm.EOS): 1, ('妳', word_lm.EOS): 9})
        data = word_lm.export(['你', '妳'], uni, pairs)
        self.assertEqual(data, word_lm.export(['妳', '你'], uni, Counter(dict(reversed(list(pairs.items()))))))
        magic, version, vocab, count, tokens, discount = struct.unpack_from('<4sIIIQd', data)
        self.assertEqual((magic, version, vocab, count, tokens, discount), (b'MWLM', 1, 5, 4, 20, .75))
        records = [struct.unpack_from('<QQI', data, 32 + vocab*20 + i*20) for i in range(count)]
        self.assertIn((word_lm.key(word_lm.BOS), word_lm.key('你'), 1), records)
        self.assertEqual(records, sorted(records))

    def test_unknown_and_single_character_runs(self):
        class FakeLex:
            score = {'你': -5}
            def segment(self, text):
                return list(text)
        word_lm.lex = FakeLex()
        u, pairs = word_lm.count_batch(['你！龘'])
        self.assertEqual(u[word_lm.EOS], 2)
        self.assertEqual(u[word_lm.UNK], 1)
        self.assertEqual(pairs[(word_lm.BOS, '你')], 1)
        self.assertEqual(pairs[(word_lm.UNK, word_lm.EOS)], 1)

    def test_incomplete_counts_rejected(self):
        with self.assertRaises(ValueError):
            word_lm.export(['你'], Counter({'你': 2}), Counter({(word_lm.BOS, '你'): 1}))

    def test_mixed_gain_cannot_hide_chinese_clean_loss(self):
        from types import SimpleNamespace
        from eval_word_lm import guarded
        cases = {'zh': SimpleNamespace(track='zh', persona='clean', expected='你好'),
                 'mixed': SimpleNamespace(track='mixed', persona='clean', expected='hi')}
        before = {'zh': {'exact': True, 'reached': True, 'picks': 0},
                  'mixed': {'exact': False, 'reached': True, 'picks': 1}}
        after = {'zh': {'exact': False, 'reached': True, 'picks': 1},
                 'mixed': {'exact': True, 'reached': True, 'picks': 0}}
        self.assertFalse(guarded(after, before, list(cases), cases))
