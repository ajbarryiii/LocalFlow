"""Contract tests for forced-alignment frame labels (lfspk.harness.forced): interval
to frame conversion, CTC transcript normalisation and span grouping, and that
mixture labels are exactly the padded word intervals."""

import json
import unittest

import numpy as np

from lfspk.api import frame_count
from lfspk.harness.forced import GAP_S, PAD_S, activity_from_alignment, group_word_spans, merge_gaps, transcript_tokens, words_to_frames
from lfspk.harness.mix import MixtureGenerator
from lfspk.harness.synthetic import SyntheticCorpus


class FramesTest(unittest.TestCase):
    def test_boundaries_and_padding(self):
        # Word 0.100-0.200 s padded 40 ms -> [0.06, 0.24) -> frames 6..23.
        a = words_to_frames([["a", 0.10, 0.20]], 40)
        np.testing.assert_array_equal(np.flatnonzero(a), np.arange(6, 24))
        b = words_to_frames([["a", 0.10, 0.20]], 40, pad_s=0.0)
        np.testing.assert_array_equal(np.flatnonzero(b), np.arange(10, 20))
        # A boundary inside a frame activates that frame.
        c = words_to_frames([["a", 0.105, 0.195]], 40, pad_s=0.0)
        np.testing.assert_array_equal(np.flatnonzero(c), np.arange(10, 20))

    def test_gap_merging(self):
        # A 150 ms gap (< 200 ms) is within-phrase: merged, no hole.
        a = words_to_frames([["a", 0.0, 0.1], ["b", 0.25, 0.4]], 60, pad_s=0.0)
        self.assertTrue(a[:40].all() and not a[40:].any())
        # A 300 ms pause stays a pause, shortened by the padding on both sides.
        b = words_to_frames([["a", 0.0, 0.1], ["b", 0.4, 0.5]], 60)
        self.assertTrue(b[:14].all() and b[36:54].all())
        self.assertFalse(b[14:36].any() or b[54:].any())
        # Order of the input does not matter.
        np.testing.assert_array_equal(words_to_frames([["b", 0.4, 0.5], ["a", 0.0, 0.1]], 60), b)
        self.assertEqual(merge_gaps([["a", 0.0, 0.1], ["b", 0.25, 0.4], ["c", 0.7, 0.8]]), [(0.0, 0.4), (0.7, 0.8)])

    def test_final_partial_frame_and_clipping(self):
        n = 16000 + 80  # 100.5 frames -> 101
        a = activity_from_alignment([["a", 0.9, 0.98]], n)
        self.assertEqual(a.size, frame_count(n))
        self.assertTrue(a[-1])  # 0.98 + 0.04 reaches into the final partial frame
        self.assertFalse(words_to_frames([["a", 2.0, 3.0]], 10).any())
        self.assertEqual(words_to_frames([], 5).tolist(), [False] * 5)
        self.assertEqual((PAD_S, GAP_S), (0.04, 0.2))


class CtcTextTest(unittest.TestCase):
    D = {c: i for i, c in enumerate(["-", "|", "E", "T", "A", "O", "N", "I", "H", "S", "R", "D", "L", "U", "M", "W", "C", "F", "G", "Y", "P", "B", "V", "K", "'", "X", "J", "Q", "Z"])}

    def test_tokens(self):
        words, t = transcript_tokens("IT'S A DOG", self.D)
        self.assertEqual(words, ["IT'S", "A", "DOG"])
        inv = {v: k for k, v in self.D.items()}
        self.assertEqual("".join(inv[i] for i in t), "IT'S|A|DOG")

    def test_out_of_vocabulary(self):
        words, t = transcript_tokens("café 42 - naïve", self.D)
        inv = {v: k for k, v in self.D.items()}
        # Lower case is folded; characters outside the vocabulary are dropped; a word with none left is dropped.
        self.assertEqual(words, ["CAFÉ", "NAÏVE"])
        self.assertEqual("".join(inv[i] for i in t), "CAF|NAVE")

    def test_group_spans(self):
        sep = self.D["|"]
        spans = [(3, 5, 6), (9, 6, 8), (sep, 8, 10), (4, 12, 13)]  # "TS" "|" "A", frames of 20 ms
        out = group_word_spans(spans, ["TS", "A"], sep, 0.02)
        self.assertEqual(out, [["TS", 0.1, 0.16], ["A", 0.24, 0.26]])
        with self.assertRaises(ValueError):
            group_word_spans(spans, ["TS", "A", "B"], sep, 0.02)


class MixtureLabelsFromAlignmentTest(unittest.TestCase):
    def test_target_labels_are_padded_word_intervals(self):
        with SyntheticCorpus() as corpus:
            gen = MixtureGenerator("dev", corpus)
            u = corpus.utterances["100"][0]
            m = gen.render("S0", 3, target=u)
            off = m.meta["target"]["parts"][0][0]
            words = [[w, s + off / 100, e + off / 100] for w, s, e in corpus.alignment(u.id)]
            np.testing.assert_array_equal(m.target_active, words_to_frames(words, m.labels.size))

    def test_missing_alignment_is_an_error(self):
        with SyntheticCorpus() as corpus:
            p = corpus.align_dir / "dev.jsonl"
            rows = [json.loads(l) for l in p.read_text().splitlines()]
            victim = rows[0]["id"]
            p.write_text("".join(json.dumps(r) + "\n" for r in rows[1:]))
            gen = MixtureGenerator("dev", corpus)
            with self.assertRaises(RuntimeError):
                gen.render("S0", 1, target=victim)


if __name__ == "__main__":
    unittest.main()


class ReviewR5RegressionTest(unittest.TestCase):
    def test_exact_200ms_gap_never_merges(self):
        # Review r5 #3: float subtraction made some 200 ms gaps 199.99... ms.
        for base in (0.1, 1.1, 7.7, 12.34, 33.3):
            ivs = merge_gaps([["a", base - 0.1, base], ["b", base + 0.2, base + 0.3]])
            self.assertEqual(len(ivs), 2, base)
            ivs = merge_gaps([["a", base - 0.1, base], ["b", base + 0.199, base + 0.3]])
            self.assertEqual(len(ivs), 1, base)
        a = words_to_frames([["a", 0.0, 0.1], ["b", 0.3, 0.4]], 60)
        self.assertFalse(a[14:26].any())  # the 120 ms left after padding stays a pause

    def test_empty_alignment_is_missing_not_silence(self):
        # Review r5 #1: an empty word list must not render as "no speech".
        with SyntheticCorpus() as corpus:
            p = corpus.align_dir / "dev.jsonl"
            rows = [json.loads(l) for l in p.read_text().splitlines()]
            victim = rows[0]["id"]
            rows.append({"id": victim, "method": "parakeet-tdt-v2", "words": []})
            p.write_text("".join(json.dumps(r) + "\n" for r in rows))
            self.assertIsNone(corpus.alignment(victim))
            with self.assertRaises(RuntimeError):
                MixtureGenerator("dev", corpus).render("S0", 1, target=victim)

    def test_truncated_final_record_tolerated_other_garbage_raises(self):
        # Review r5 #5.
        import tempfile
        from pathlib import Path

        from lfspk.harness.forced import read_jsonl, truncate_incomplete_tail

        with tempfile.TemporaryDirectory(dir="/tmp") as d:
            p = Path(d) / "a.jsonl"
            p.write_text('{"id": "x", "method": "m", "words": [["A", 0.1, 0.2]]}\n{"id": "y", "meth')
            self.assertEqual([r["id"] for r in read_jsonl(p)], ["x"])
            self.assertGreater(truncate_incomplete_tail(p), 0)
            self.assertTrue(p.read_text().endswith("\n"))
            self.assertEqual(truncate_incomplete_tail(p), 0)
            p.write_text('{"id": "x"\n{"id": "y", "method": "m", "words": []}\n')
            with self.assertRaises(json.JSONDecodeError):
                read_jsonl(p)

    def test_relabel_reproduces_rendered_labels_and_no_merge_variant(self):
        from lfspk.harness.forced import NO_MERGE_GAP_S
        from lfspk.harness.mix import SCENARIOS, relabel

        with SyntheticCorpus() as corpus:
            gen = MixtureGenerator("dev", corpus)
            for seed in range(3):
                g = gen.render_paired(SCENARIOS, seed)
                for m in g.values():
                    lab, t, ints = relabel(corpus, m.meta, GAP_S)
                    np.testing.assert_array_equal(lab, m.labels)
                    np.testing.assert_array_equal(t, m.target_active)
                    lab0, t0, _ = relabel(corpus, m.meta, NO_MERGE_GAP_S)
                    self.assertTrue(np.all(t0 <= t))  # no-merge only removes frames
