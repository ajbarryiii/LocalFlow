import os
import unittest

from lfspk import paths, splits


class ParseTest(unittest.TestCase):
    def test_parse_skips_comments_and_reads_fields(self):
        text = ";ID |SEX| SUBSET | MINUTES | NAME\n14   | F | train-clean-360  | 25.03 | A B\n\n"
        self.assertEqual(splits.parse_speakers_txt(text), {"14": ("F", "train-clean-360")})


@unittest.skipUnless(os.path.isdir(paths.LIBRISPEECH), "LibriSpeech not available")
class RealSplitsTest(unittest.TestCase):
    def test_counts_and_disjoint(self):
        got = {name: splits.speakers(name) for name in splits.SPLIT_SUBSETS}
        self.assertEqual({k: len(v) for k, v in got.items()}, {"train": 921, "dev": 73, "test": 73})
        ids = [s.id for v in got.values() for s in v]
        self.assertEqual(len(ids), len(set(ids)))
        self.assertTrue(all(s.sex in ("F", "M") for v in got.values() for s in v))

    def test_clone_eval_is_auxiliary_and_disjoint(self):
        self.assertNotIn("clone_eval", splits.SPLIT_SUBSETS)
        if not (paths.LIBRISPEECH / "train-clean-100").is_dir():
            self.skipTest("train-clean-100 not available")
        aux = {s.id for s in splits.speakers("clone_eval")}
        self.assertEqual(len(aux), 251)
        main = {s.id for name in splits.SPLIT_SUBSETS for s in splits.speakers(name)}
        self.assertFalse(aux & main)

    def test_utterances_exist(self):
        spk = splits.speakers("dev")[0]
        self.assertTrue(splits.utterances(spk))


if __name__ == "__main__":
    unittest.main()
