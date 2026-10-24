import unittest

import numpy as np

from lfspk.probe import metrics as M


def brute_eer(scores, labels):
    """EER by scanning every threshold; returns the interval of (P_miss + P_fa)/2 at the crossing."""
    t = np.sort(np.unique(scores))
    best = None
    for th in np.r_[t, t[-1] + 1]:
        pm = np.mean(scores[labels] < th)
        pf = np.mean(scores[~labels] >= th)
        if best is None or abs(pm - pf) < best[0]:
            best = (abs(pm - pf), (pm + pf) / 2)
    return best[1]


class TestDetection(unittest.TestCase):
    def test_perfect_and_inverted(self):
        s = np.array([0.1, 0.2, 0.8, 0.9])
        y = np.array([0, 0, 1, 1])
        self.assertAlmostEqual(M.eer(s, y), 0.0)
        self.assertAlmostEqual(M.auc(s, y), 1.0)
        self.assertAlmostEqual(M.min_dcf(s, y), 0.0)
        self.assertAlmostEqual(M.eer(-s, y), 1.0)
        self.assertAlmostEqual(M.auc(-s, y), 0.0)

    def test_all_ties_is_chance(self):
        s = np.zeros(10)
        y = np.array([0, 1] * 5)
        self.assertAlmostEqual(M.auc(s, y), 0.5)
        self.assertAlmostEqual(M.eer(s, y), 0.5)
        self.assertAlmostEqual(M.min_dcf(s, y), 1.0)  # best is accept or reject all

    def test_gaussian_eer_matches_theory_and_brute_force(self):
        rng = np.random.default_rng(0)
        n = 20000
        s = np.r_[rng.normal(1.0, 1, n), rng.normal(-1.0, 1, n)]
        y = np.r_[np.ones(n, bool), np.zeros(n, bool)]
        # theoretical EER = Phi(-1) = 0.1587
        self.assertAlmostEqual(M.eer(s, y), 0.1587, delta=0.006)
        self.assertAlmostEqual(M.eer(s, y), brute_eer(s, y), delta=1e-3)
        # theoretical AUC = Phi(2/sqrt(2)) = 0.9214
        self.assertAlmostEqual(M.auc(s, y), 0.9214, delta=0.005)

    def test_auc_matches_pairwise_definition_with_ties(self):
        rng = np.random.default_rng(1)
        s = rng.integers(0, 5, 200).astype(float)
        y = rng.random(200) < 0.4
        pos, neg = s[y], s[~y]
        ref = ((pos[:, None] > neg[None, :]).mean() + 0.5 * (pos[:, None] == neg[None, :]).mean())
        self.assertAlmostEqual(M.auc(s, y), ref, places=10)

    def test_integer_weights_equal_replication(self):
        rng = np.random.default_rng(2)
        s = rng.normal(size=300)
        y = rng.random(300) < 0.3
        s = s + y
        w = rng.integers(0, 4, 300).astype(float)
        rep = np.repeat(np.arange(300), w.astype(int))
        st = M.SortedTrials(s, y)
        self.assertAlmostEqual(st.eer(w), M.eer(s[rep], y[rep]), places=10)
        self.assertAlmostEqual(st.min_dcf(w), M.min_dcf(s[rep], y[rep]), places=10)
        self.assertAlmostEqual(st.auc(w), M.auc(s[rep], y[rep]), places=10)
        e, d = st.eer_dcf(w)
        self.assertAlmostEqual(e, st.eer(w))
        self.assertAlmostEqual(d, st.min_dcf(w))

    def test_min_dcf_hand_example(self):
        # one target below two non-targets: best is reject all (P_miss=1): cost 0.01 -> normalised 1
        s = np.array([0.0, 1.0, 2.0])
        y = np.array([1, 0, 0])
        self.assertAlmostEqual(M.min_dcf(s, y), 1.0)
        # separable -> 0
        self.assertAlmostEqual(M.min_dcf(np.array([3.0, 1.0, 2.0]), y), 0.0)

    def test_rejects_one_class(self):
        with self.assertRaises(ValueError):
            M.eer(np.array([1.0, 2.0]), np.array([1, 1]))


class TestGrouped(unittest.TestCase):
    def test_matches_sorted_trials_with_ties(self):
        rng = np.random.default_rng(9)
        n, g = 3000, 17
        groups = rng.integers(0, g, n)
        y = rng.random(n) < 0.4
        s = np.round(rng.normal(size=n) + y, 1)  # many ties
        gt = M.GroupedTrials(s, y, groups, g)
        st = M.SortedTrials(s, y)
        for wg in (None, rng.integers(0, 3, g).astype(float)):
            w = None if wg is None else wg[groups]
            np.testing.assert_allclose(gt.auc_eer(wg)[:2], [st.auc(w), st.eer(w)], atol=1e-12)

    def test_fa_at_miss(self):
        # positives 1..100, negatives 0.5..99.5 step 1 (100 each). At most 2 % miss: the strictest
        # threshold drops positives 1, 2 and every negative below 3 (0.5, 1.5, 2.5) -> 97 % kept;
        # at most 1 % miss: drop positive 1 and negatives 0.5, 1.5 -> 98 % kept.
        pos = np.arange(1, 101, dtype=float)
        neg = np.arange(100, dtype=float) + 0.5
        s = np.r_[pos, neg]
        y = np.r_[np.ones(100, bool), np.zeros(100, bool)]
        gt = M.GroupedTrials(s, y, np.zeros(200, int), 1)
        auc, eer, fa1, fa2 = gt.auc_eer()
        self.assertAlmostEqual(fa2, 0.97)
        self.assertAlmostEqual(fa1, 0.98)
        sep = M.GroupedTrials(np.r_[pos + 1000, neg], y, np.zeros(200, int), 1)
        self.assertEqual(sep.auc_eer()[3], 0.0)

    def test_validation(self):
        with self.assertRaises(ValueError):
            M.GroupedTrials(np.zeros(2), np.array([1, 0]), np.array([0, 2]), 2)
        gt = M.GroupedTrials(np.zeros(2), np.array([1, 0]), np.array([0, 1]), 2)
        with self.assertRaises(ValueError):
            gt.auc_eer(np.array([1.0, 0.0]))


class TestBootstrap(unittest.TestCase):
    def test_resample_weights_shape_and_sum(self):
        w = M.resample_weights(7, 50, 3)
        self.assertEqual(w.shape, (50, 7))
        self.assertTrue(np.all(w.sum(1) == 7))
        np.testing.assert_array_equal(w, M.resample_weights(7, 50, 3))

    def test_stratified_resample_keeps_stratum_sizes(self):
        strata = np.array([0, 0, 0, 1, 1, 2, 2, 2, 2])
        w = M.resample_weights(9, 200, 1, strata=strata)
        for st, size in ((0, 3), (1, 2), (2, 4)):
            self.assertTrue(np.all(w[:, strata == st].sum(1) == size))
        self.assertGreater(w.std(), 0)

    def test_ci_covers_and_is_by_group(self):
        rng = np.random.default_rng(4)
        # 40 groups with very different per-group means: group-level CI must be wide
        g = np.repeat(np.arange(40), 50)
        x = rng.normal(size=40)[g] + 0.01 * rng.normal(size=g.size)
        mult = M.resample_weights(40, 500, 0)

        def mean(w):
            return float(np.average(x, weights=None if w is None else w))
        est = M.bootstrap(mean, M.one_way(g), mult)
        self.assertTrue(est.lo < est.value < est.hi)
        # standard error of a mean of 40 unit-variance group means is ~0.16 -> CI width ~0.6
        self.assertGreater(est.hi - est.lo, 0.35)

    def test_two_way_weights(self):
        ge = np.array([0, 0, 1, 1])
        gt = np.array([0, 1, 0, 1])
        tg = ge == gt
        w = M.two_way(ge, gt, tg)(np.array([2.0, 0.0]))
        np.testing.assert_array_equal(w, [2.0, 0.0, 0.0, 0.0])  # target counted once per copy; pair needs both
        w = M.two_way(ge, gt, tg)(np.array([2.0, 3.0]))
        np.testing.assert_array_equal(w, [2.0, 6.0, 6.0, 3.0])
        with self.assertRaises(ValueError):
            M.two_way(ge, gt, np.array([True, True, False, False]))

    def test_two_way_captures_test_speaker_variability(self):
        """One impostor speaker whose recordings score high against every model:
        enrollment-only resampling cannot see that this speaker could be absent
        or repeated; the two-way interval is much wider."""
        rng = np.random.default_rng(6)
        n = 30
        models = np.repeat(np.arange(n), 1)
        tests = np.repeat(np.arange(n), 5)
        ge = np.broadcast_to(models[:, None], (n, tests.size)).ravel()
        gt = np.broadcast_to(tests[None, :], (n, tests.size)).ravel()
        tg = ge == gt
        s = np.where(tg, 2.0, 0.0) + rng.normal(scale=0.5, size=tg.size)
        s[(gt == 7) & ~tg] += 2.5  # a hard impostor
        st = M.SortedTrials(s, tg)
        mult = M.resample_weights(n, 400, 1)
        one = M.bootstrap(st.eer, M.one_way(ge), mult)
        two = M.bootstrap(st.eer, M.two_way(ge, gt, tg), mult)
        self.assertAlmostEqual(one.value, two.value)
        self.assertGreater(two.hi - two.lo, 1.5 * (one.hi - one.lo))

    def test_pair_weights(self):
        w = M.pair_weights(np.array([0, 1]), np.array([1, 2]))(np.array([1.0, 2.0, 0.0]))
        np.testing.assert_array_equal(w, [2.0, 0.0])

    def test_paired_difference_of_identical_stats_is_zero(self):
        rng = np.random.default_rng(5)
        g = np.repeat(np.arange(10), 20)
        s = rng.normal(size=g.size)
        y = rng.random(g.size) < 0.5
        st = M.SortedTrials(s, y)
        d = M.bootstrap(M.difference(st.eer_dcf, st.eer_dcf), M.one_way(g), M.resample_weights(10, 100, 0))
        for e in d:
            self.assertEqual((e.value, e.lo, e.hi), (0.0, 0.0, 0.0))

    def test_undefined_resamples_give_nan_ci(self):
        g = np.array([0, 1])
        y = np.array([1, 0])
        st = M.SortedTrials(np.array([1.0, 0.0]), y)
        est = M.bootstrap(st.eer, M.one_way(g), M.resample_weights(2, 200, 0))
        self.assertTrue(np.isnan(est.lo))


if __name__ == "__main__":
    unittest.main()
