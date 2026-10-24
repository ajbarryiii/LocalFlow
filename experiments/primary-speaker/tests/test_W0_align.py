"""Contract tests for normalisation, time-constrained alignment and attribution."""

import unittest

import numpy as np

from lfspk.harness.align import (
    TOLERANCE_S,
    INS,
    INTERFERER,
    MATCH,
    OTHER,
    SUB,
    TARGET,
    Word,
    align,
    attribute,
    error_counts,
    frame_span,
    normalize,
    tokens_from_words,
    transfer_times,
    word_region,
)


def W(text, s, e):
    return Word(text, s, e)


class NormaliseTest(unittest.TestCase):
    def test_basic(self):
        self.assertEqual(normalize("Hello, World! It's well-known."), ["hello", "world", "it's", "well", "known"])
        self.assertEqual(normalize("CAFÉ 'quoted'"), ["cafe", "quoted"])

    def test_numbers(self):
        self.assertEqual(normalize("3"), ["three"])
        self.assertEqual(normalize("21st"), ["twenty", "first"])
        self.assertEqual(normalize("1,000"), ["one", "thousand"])
        self.assertEqual(normalize("105"), ["one", "hundred", "and", "five"])
        self.assertEqual(normalize("1865"), ["eighteen", "sixty", "five"])
        self.assertEqual(normalize("1905"), ["nineteen", "o", "five"])
        self.assertEqual(normalize("50%"), ["fifty", "percent"])

    def test_tokens_inherit_span(self):
        t = tokens_from_words([("well-known", 1.0, 1.5), ("!", 1.6, 1.7), ("cat", 2.0, 2.2)])
        self.assertEqual([w.text for w in t], ["well", "known", "cat"])
        self.assertEqual([(w.start, w.end, w.parent) for w in t], [(1.0, 1.5, 0), (1.0, 1.5, 0), (2.0, 2.2, 2)])


class AlignTest(unittest.TestCase):
    def test_untimed_counts_are_edit_distance(self):
        hyp = [W(t, 0, 0) for t in "the cat sat on mat".split()]
        ref = [W(t, 0, 0) for t in "the cat sat on the mat".split()]
        c = error_counts(align(hyp, ref, timed=False))
        self.assertEqual((c["C"], c["S"], c["D"], c["I"]), (5, 0, 1, 0))
        hyp = [W(t, 0, 0) for t in "a cat sat x on the mat".split()]
        c = error_counts(align(hyp, ref, timed=False))
        self.assertEqual(c["S"] + c["D"] + c["I"], 2)

    def test_timing_prevents_cross_time_match(self):
        # The interferer says "the" at 5 s; the target's "the" is at 1 s.
        ref = [W("the", 1.0, 1.2), W("dog", 1.3, 1.6)]
        hyp = [W("dog", 1.3, 1.6), W("the", 5.0, 5.2)]
        ops = align(hyp, ref, timed=True)
        c = error_counts(ops)
        self.assertEqual((c["C"], c["D"], c["I"]), (1, 1, 1))
        c2 = error_counts(align(hyp, ref, timed=False))
        self.assertEqual(c2["S"] + c2["D"] + c2["I"], 2)  # same edit distance, but untimed may pair across time

    def test_tolerance(self):
        # 0.5 s since dev-v1 (Parakeet vs CTC timing).
        ref = [W("a", 1.0, 1.2)]
        self.assertEqual(TOLERANCE_S, 0.5)
        self.assertEqual(align([W("a", 1.65, 1.8)], ref)[0][0], MATCH)
        self.assertNotEqual(align([W("a", 1.75, 1.8)], ref)[0][0], MATCH)
        self.assertEqual(align([W("a", 0.2, 0.5)], ref)[0][0], MATCH)
        self.assertNotEqual(align([W("a", 0.2, 0.45)], ref)[0][0], MATCH)

    def test_most_matches_among_minimum_edit_alignments(self):
        # Two minimum-edit alignments: the one with the exact match wins.
        hyp = [W("hello", 0.1, 0.4), W("world", 0.5, 0.9), W("buy", 1.2, 1.4)]
        ref = [W("buy", 1.2, 1.4), W("now", 1.6, 1.9), W("today", 2.2, 2.6)]
        ops = align(hyp, ref)
        self.assertIn(("C", 2, 0), ops)
        self.assertEqual(sum(1 for o in ops if o[0] != "C"), 4)

    def test_repeated_word_pairs_with_closest_occurrence(self):
        # Eval r5 #2: target "go" at 0.10 s, interferer repeats "go" at 0.60 s.
        ref = [W("go", 0.10, 0.20), W("anchor", 0.9, 1.2)]
        hyp = [W("go", 0.10, 0.20), W("go", 0.60, 0.70), W("anchor", 0.9, 1.2)]
        ops = align(hyp, ref)
        self.assertIn(("C", 0, 0), ops)
        self.assertIn(("I", 1, -1), ops)
        self.assertEqual(error_counts(ops), error_counts(align(hyp, ref, timed=False)) | {"C": 2})
        att = attribute(hyp, ref, [[W("go", 0.60, 0.70)]], np.ones(150, np.uint8))
        self.assertEqual((att[0].source, att[0].kind), (TARGET, MATCH))
        self.assertEqual((att[1].source, att[1].kind), (INTERFERER, MATCH))

    def test_wer_counts_are_minimum_edit(self):
        rng = np.random.default_rng(0)
        vocab = ["a", "b", "c", "d"]
        for _ in range(200):
            ref = [W(str(rng.choice(vocab)), 0.3 * k, 0.3 * k + 0.2) for k in range(int(rng.integers(0, 8)))]
            hyp = [W(str(rng.choice(vocab)), 0.3 * k + float(rng.uniform(-0.2, 0.2)), 0.3 * k + 0.2) for k in range(int(rng.integers(0, 8)))]
            e = error_counts(align(hyp, ref, timed=False))
            # Plain Levenshtein distance.
            Dm = np.arange(len(ref) + 1)
            for i in range(1, len(hyp) + 1):
                prev, Dm = Dm, np.empty_like(Dm)
                Dm[0] = i
                for j in range(1, len(ref) + 1):
                    Dm[j] = min(prev[j] + 1, Dm[j - 1] + 1, prev[j - 1] + (hyp[i - 1].text != ref[j - 1].text))
            self.assertEqual(e["S"] + e["D"] + e["I"], Dm[-1])

    def test_decision_span_widening_and_clipping(self):
        from lfspk.harness.align import WORD_WIDEN_S, decision_span

        self.assertEqual(WORD_WIDEN_S, 0.08)
        self.assertEqual(decision_span(1.0, 1.2, 300), (92, 128))
        self.assertEqual(decision_span(0.03, 0.1, 300), (0, 18))  # clipped at the start
        self.assertEqual(decision_span(2.95, 3.0, 300), (287, 300))  # clipped at the end

    def test_empty(self):
        self.assertEqual(align([], []), [])
        self.assertEqual(error_counts(align([], [W("a", 0, 1)]))["D"], 1)
        self.assertEqual(error_counts(align([W("a", 0, 1)], []))["I"], 1)


class TransferTimesTest(unittest.TestCase):
    def test_copy_and_interpolate(self):
        hyp = [W("a", 0.0, 0.2), W("c", 1.0, 1.2)]
        out = transfer_times(["a", "b", "c"], hyp, (0.0, 2.0))
        self.assertEqual((out[0].start, out[0].end), (0.0, 0.2))
        self.assertEqual((out[2].start, out[2].end), (1.0, 1.2))
        self.assertAlmostEqual(out[1].start, 0.2)
        self.assertAlmostEqual(out[1].end, 1.0)

    def test_no_hypothesis_spreads_over_fallback(self):
        out = transfer_times(["a", "b"], [], (1.0, 3.0))
        self.assertEqual([(w.start, w.end) for w in out], [(1.0, 2.0), (2.0, 3.0)])


class AttributionTest(unittest.TestCase):
    def setUp(self):
        # 3 s timeline: target speaks 0-1.5 s, interferer 1.0-3.0 s.
        self.labels = np.zeros(300, np.uint8)
        self.labels[:100] = 1
        self.labels[100:150] = 3
        self.labels[150:] = 2
        self.target = [W("hello", 0.1, 0.4), W("world", 0.5, 0.9), W("again", 1.1, 1.4)]
        self.inter = [[W("buy", 1.2, 1.4), W("now", 1.6, 1.9), W("today", 2.2, 2.6)]]

    def test_matches_substitutions_insertions(self):
        hyp = [W("hello", 0.1, 0.4), W("word", 0.5, 0.9), W("again", 1.1, 1.4), W("now", 1.6, 1.9), W("today", 2.2, 2.6), W("uh", 2.8, 2.9)]
        att = attribute(hyp, self.target, self.inter, self.labels)
        self.assertEqual([(a.source, a.kind) for a in att],
                         [(TARGET, MATCH), (TARGET, SUB), (TARGET, MATCH), (INTERFERER, MATCH), (INTERFERER, MATCH), (INTERFERER, INS)])

    def test_simultaneous_same_word_is_flagged_ambiguous(self):
        # Review eval r1 #6: both speakers say "go" at once.
        target = [W("go", 0.5, 0.7)]
        inter = [[W("go", 0.5, 0.7)]]
        att = attribute([W("go", 0.5, 0.7)], target, inter, self.labels)
        self.assertEqual((att[0].source, att[0].kind, att[0].ambiguous), (TARGET, MATCH, True))
        att = attribute([W("hello", 0.1, 0.4)], self.target, self.inter, self.labels)
        self.assertFalse(att[0].ambiguous)

    def test_exact_match_beats_substitution(self):
        # "buy" overlaps target "again" in time but exactly matches the interferer.
        hyp = [W("hello", 0.1, 0.4), W("world", 0.5, 0.9), W("buy", 1.2, 1.4)]
        att = attribute(hyp, self.target, self.inter, self.labels)
        self.assertEqual((att[2].source, att[2].kind), (INTERFERER, MATCH))

    def test_unaligned_in_silence_is_other(self):
        labels = np.zeros(300, np.uint8)
        att = attribute([W("um", 1.0, 1.1)], [], [[]], labels)
        self.assertEqual(att[0].source, OTHER)

    def test_unaligned_in_target_speech_is_target_insertion(self):
        att = attribute([W("zzz", 0.2, 0.3)], [], [[]], self.labels)
        self.assertEqual((att[0].source, att[0].kind), (TARGET, INS))

    def test_regions_and_frames(self):
        self.assertEqual(frame_span(0.0, 0.0, 300), (0, 1))
        self.assertEqual(frame_span(0.105, 0.2, 300), (10, 20))
        self.assertEqual(frame_span(5.0, 6.0, 300), (299, 300))
        self.assertEqual(word_region(W("x", 1.0, 1.5), self.labels), "overlap")
        self.assertEqual(word_region(W("x", 0.0, 0.5), self.labels), "single")


if __name__ == "__main__":
    unittest.main()


class PlacedReferenceTest(unittest.TestCase):
    def test_placed_words_follow_placements(self):
        from lfspk.harness.mix import MixtureGenerator
        from lfspk.harness.refs import placed_words
        from lfspk.harness.synthetic import SyntheticCorpus

        with SyntheticCorpus() as corpus:
            gen = MixtureGenerator("dev", corpus)
            for scen in ("S0", "S1", "S3", "S4"):
                for seed in range(3):
                    m = gen.render(scen, seed)
                    F = m.labels.size
                    tw = placed_words(corpus, m.meta["target"]["placements"], F, min_inside=0.0)
                    # Every target word sits inside the labelled target activity.
                    for w in tw:
                        f0, f1 = frame_span(w.start, w.end, F)
                        self.assertTrue(m.target_active[f0:f1].mean() > 0.9, (scen, w))
                    n_words = sum(len(corpus.alignment(p[0])) for p in m.meta["target"]["placements"])
                    if scen != "S3":
                        self.assertEqual(len(tw), n_words * 1)  # synthetic words normalise to one token
                    for it, a in zip(m.meta["interferers"], m.interferer_actives):
                        for w in placed_words(corpus, it["placements"], F):
                            f0, f1 = frame_span(max(0.0, w.start), min(w.end, F / 100), F)
                            self.assertTrue(a[f0:f1].any(), (scen, w))

    def test_cut_words_need_half_inside(self):
        from lfspk.harness.refs import placed_words

        class C:
            def alignment(self, uid):
                return [["A", 0.0, 1.0], ["B", 1.2, 2.0], ["C", 2.2, 3.0]]

        # Slice 0.6-2.5 s of the utterance placed at 0: A has 40 % inside (dropped), B all, C 37.5 % (dropped).
        ws = placed_words(C(), [["u", 60, 250, 60]], 400)
        self.assertEqual([w.text for w in ws], ["b"])
        self.assertEqual((ws[0].start, ws[0].end), (1.2, 2.0))
        # Review eval r1 #5: exactly half audible counts (integer milliseconds).
        ws = placed_words(C(), [["u", 160, 300, 160]], 400)
        self.assertIn("b", [w.text for w in ws])
        # Shifted: the same slice placed at timeline 1.0 s moves times by +0.4 s.
        ws = placed_words(C(), [["u", 60, 250, 100]], 400)
        self.assertEqual((ws[0].start, ws[0].end), (1.6, 2.4))
