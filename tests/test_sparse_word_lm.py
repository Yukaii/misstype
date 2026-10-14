from pathlib import Path
import struct
import sys
import unittest

sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'tools'))
from word_lm import key,BOS,EOS,UNK
from prune_word_lm import export


class SparseModelTests(unittest.TestCase):
    def setUp(self):
        self.words=sorted([(key('你'),1,1,1),(key('妳'),9,9,1),
                          (key(BOS),0,10,2),(key(EOS),10,0,0),(key(UNK),0,0,0)])

    def test_removed_mass_goes_to_unigram_not_zero(self):
        data=export(self.words,[(key(BOS),key('妳'),9)],20)
        n=struct.unpack_from('<I',data,8)[0]
        records={h:(p,b) for h,p,b in (struct.unpack_from('<Qff',data,32+i*16) for i in range(n))}
        self.assertAlmostEqual(sum(p for p,_ in records.values()),1,places=6)
        self.assertAlmostEqual(records[key(BOS)][1],.175,places=6)
        self.assertEqual(records[key('你')][1],1)
        self.assertAlmostEqual(struct.unpack_from('<f',data,len(data)-4)[0],.825,places=6)

    def test_unigram_only_is_a_valid_backoff_distribution(self):
        data=export(self.words,[],20)
        self.assertEqual(len(data),32+len(self.words)*16)
        for i in range(len(self.words)):
            self.assertEqual(struct.unpack_from('<f',data,32+i*16+12)[0],1)

    def test_invalid_duplicates_or_excess_mass_rejected(self):
        with self.assertRaises(ValueError):
            export(self.words,[(key(BOS),key('妳'),9)]*2,20)
        with self.assertRaises(ValueError):
            export(self.words,[(key(BOS),key('妳'),20)],20)
