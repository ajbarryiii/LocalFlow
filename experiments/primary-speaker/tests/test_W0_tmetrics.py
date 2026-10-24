"""Contract tests of lfspk.harness.tmetrics (DESIGN.md 14.2 fe-7, fe-8, fe-9):
transcript metrics relative to B by reference-word identity, the joint speaker
bootstrap draws, and the exact re-aligned threshold search. Synthetic words
only; every expected value below is computed by hand in the comments."""

import hashlib
import json
import unittest
from pathlib import Path

import numpy as np

from lfspk.harness import metrics as M
from lfspk.harness import tmetrics as T
from lfspk.harness.align import Word, align


def W(text, s, e):
    return Word(text, s, e)


def labels_fixture():
    """300 frames (3 s): target 0-0.8 s (overlap 0.3-0.5 s), interferer only
    0.8-1.0 s, target 2.0-2.2 s, silence elsewhere."""
    lab = np.zeros(300, np.uint8)
    lab[0:80] = 1
    lab[30:50] = 3
    lab[80:100] = 2
    lab[200:220] = 1
    return lab


REF = [W("a", 0.0, 0.2), W("b", 0.3, 0.5), W("c", 0.6, 0.8), W("d", 2.0, 2.2)]  # regions s, o, s, s
INT = [[W("x", 0.85, 0.95)]]
# B: a = C; q substitutes b (overlap); x (interferer word) substitutes c; d deleted;
# zz (2.8 s, silence, compatible with nothing) is an insertion attributed to "other".
B_HYP = [W("a", 0.0, 0.2), W("q", 0.3, 0.5), W("x", 0.85, 0.95), W("zz", 2.8, 2.9)]
# X: a, b, c correct; d deleted.
X_HYP = [W("a", 0.0, 0.2), W("b", 0.3, 0.5), W("c", 0.6, 0.8)]


class EvaluateHypTest(unittest.TestCase):
    def test_hand_computed_fixture(self):
        e = T.evaluate_hyp(B_HYP, REF, INT, labels_fixture())
        self.assertEqual(e.correct, frozenset({0}))
        self.assertEqual(e.ref_region, (0, 1, 0, 0))
        self.assertEqual(e.S, (1, 1))  # c single, b overlap (by reference region)
        self.assertEqual(e.D, (1, 0))  # d
        self.assertEqual(e.I, (1, 0))  # zz, by token region
        self.assertEqual(e.n_int, (1, 0))  # x, token in label-2 frames
        self.assertEqual(e.n_other, (1, 0))  # zz
        self.assertEqual(e.n_ref, (3, 1))
        self.assertEqual(e.untimed_lost, 3)  # untimed: C a, S q/b, S x/c, D d (zz inserted)

    def test_empty_hypothesis(self):
        e = T.evaluate_hyp([], REF, INT, labels_fixture())
        self.assertEqual(e.correct, frozenset())
        self.assertEqual(e.D, (3, 1))
        self.assertEqual(e.S + e.I + e.n_int + e.n_other, (0,) * 8)
        self.assertEqual(e.untimed_lost, 4)

    def test_unreachable(self):
        # Only "a" has a same-text, time-compatible token anywhere in B.
        self.assertEqual(T.unreachable(B_HYP, REF), frozenset({1, 2, 3}))
        # Compatibility uses the 0.5 s tolerance: "d" at 2.0-2.2 is reachable from a
        # "d" token ending at 1.55 (1.55 + 0.5 >= 2.0), not from one ending at 1.45.
        self.assertNotIn(3, T.unreachable([W("d", 1.4, 1.55)], REF))
        self.assertIn(3, T.unreachable([W("d", 1.3, 1.45)], REF))

    def test_dropout_rule(self):
        e = T.evaluate_hyp(B_HYP, REF, INT, labels_fixture())  # untimed S + D = 3 of 4
        self.assertTrue(T.is_dropout(e, 0.1))
        self.assertFalse(T.is_dropout(e, 0.11))  # dry target itself too poor
        self.assertFalse(T.is_dropout(T.evaluate_hyp(X_HYP, REF, INT, labels_fixture()), 0.0))  # 1 of 4


class CountsAndSummaryTest(unittest.TestCase):
    def setUp(self):
        lab = labels_fixture()
        self.b = T.evaluate_hyp(B_HYP, REF, INT, lab)
        self.x = T.evaluate_hyp(X_HYP, REF, INT, lab)
        self.u = T.unreachable(B_HYP, REF)
        self.cx = T.mix_counts(self.x, self.b, self.u, False, True)
        self.cb = T.mix_counts(self.b, self.b, self.u, True, True)

    def test_counts_by_identity_and_region(self):
        c = self.cx
        g = lambda f, r: c[T.COL[f"{f}/{r}"]]
        self.assertEqual((g("lost", "single"), g("lost", "overlap")), (0, 0))
        self.assertEqual((g("gained", "single"), g("gained", "overlap")), (1, 1))  # c, b
        self.assertEqual((g("gained_u", "single"), g("gained_u", "overlap")), (1, 1))
        self.assertEqual((g("err_B", "single"), g("err_B", "overlap")), (3, 1))  # S c + D d + I zz | S b
        self.assertEqual(c[T.COL["dropout"]], 0)
        self.assertEqual(c[T.COL["dropout_B"]], 1)
        self.assertEqual(c[T.COL["mixtures"]], 1)

    def test_statistics_hand_computed(self):
        s = T.summarize(self.cx)
        self.assertEqual(s["L+/all"], 0.0)
        self.assertEqual(s["G/all"], 0.5)  # 2 of 4 reference words
        self.assertEqual(s["G_u/all"], 0.5)
        self.assertEqual(s["net_L/all"], -0.5)
        self.assertEqual(s["E/all"], 0.25)  # D d
        self.assertEqual(s["WER/all"], 0.25)
        self.assertEqual(s["WER_B/all"], 1.0)  # S, S, D, I over 4
        self.assertEqual(s["dWER/all"], -0.75)
        self.assertEqual(s["R/all"], 0.0)  # 0 interferer words of B's 1
        self.assertEqual(s["other/all"], 0.0)
        self.assertEqual(s["d_other/all"], -0.25)
        self.assertEqual(s["coverage/all"], 0.75)
        self.assertEqual(s["dropout"], 0.0)
        self.assertEqual(s["dropout_B"], 1.0)
        # Overlap region: only b (N = 1), which X gains; B had no interferer word there.
        self.assertEqual(s["G/overlap"], 1.0)
        self.assertEqual(s["WER_B/overlap"], 1.0)
        self.assertTrue(np.isnan(s["R/overlap"]))
        self.assertEqual(s["G/single"], 1 / 3)

    def test_b_against_itself_is_zero(self):
        s = T.summarize(self.cb)
        for k in ("L+/all", "G/all", "G_u/all", "dWER/all", "d_other/all"):
            self.assertEqual(s[k], 0.0)
        self.assertEqual(s["R/all"], 1.0)

    def test_weighted_and_vectorised(self):
        C = np.stack([self.cx, self.cb])
        w = np.array([2.0, 1.0])
        tot = T.weighted_totals(C, w)
        np.testing.assert_array_equal(tot, 2 * self.cx + self.cb)
        s = T.summarize(tot)
        self.assertAlmostEqual(s["G/all"], (2 * 2) / (3 * 4))
        self.assertAlmostEqual(s["R/all"], 1 / 3)  # X 0 x2, B 1 x1 over B 1 x2 + 1 x1
        # A batch of weight vectors gives the same statistics row by row.
        Wm = np.array([[2.0, 1.0], [0.0, 3.0], [1.0, 0.0]])
        sb = T.summarize(T.weighted_totals(C, Wm))
        for i, wi in enumerate(Wm):
            si = T.summarize(T.weighted_totals(C, wi))
            for k in ("G/all", "dWER/all", "R/all", "dropout"):
                self.assertEqual(sb[k][i], si[k])
        # A mask zeroes mixtures out.
        np.testing.assert_array_equal(T.weighted_totals(C, w, np.array([False, True])), self.cb)

    def test_empty_denominators_are_nan(self):
        s = T.summarize(np.zeros(len(T.COLS)))
        self.assertTrue(np.isnan(s["L+/all"]) and np.isnan(s["R/all"]) and np.isnan(s["dropout"]))


class RepeatedWordTest(unittest.TestCase):
    """W5's fixture (implI2-r1 #1): ref "red red" at 0.0-0.3 / 0.5-0.8, B "blue"
    0.0-0.1 and "red" 0.2-0.4. B aligns blue/red(1) S and red/red(2) C. Removing
    "blue" moves the kept red's match to ref 1 (closer start), so L+ = G = 0.5
    although no matched token was removed."""

    REF = [W("red", 0.0, 0.3), W("red", 0.5, 0.8)]
    HYP = [W("blue", 0.0, 0.1), W("red", 0.2, 0.4)]

    def test_loss_and_gain(self):
        lab = np.ones(100, np.uint8)
        b = T.evaluate_hyp(self.HYP, self.REF, [], lab)
        f = T.evaluate_hyp(self.HYP[1:], self.REF, [], lab)
        self.assertEqual(b.correct, frozenset({1}))
        self.assertEqual(f.correct, frozenset({0}))
        s = T.summarize(T.mix_counts(f, b, T.unreachable(self.HYP, self.REF), False, False))
        self.assertEqual((s["L+/all"], s["G/all"]), (0.5, 0.5))
        self.assertEqual(s["G_u/all"], 0.0)  # ref 1 has B's time-compatible "red": reachable

    def test_search_never_assumes_monotone_loss(self):
        lab = np.ones(100, np.uint8)
        b = T.evaluate_hyp(self.HYP, self.REF, [], lab)
        u = T.unreachable(self.HYP, self.REF)
        fn = lambda kept: T.mix_counts(T.evaluate_hyp(kept, self.REF, [], lab), b, u, False, False)
        steps = [T.step_counts(self.HYP, np.array([0.2, 0.9]), fn)]
        # Removing "blue" (tau in (0.2, 0.9]) already costs 1 of 2 words.
        tau, j, tot = T.search_tau(steps, np.ones(1), T.budget_rule(0.005))
        self.assertEqual(tau, 0.2)
        self.assertEqual(T.summarize(tot)["L+/all"], 0.0)
        tau, _, tot = T.search_tau(steps, np.ones(1), T.budget_rule(0.5))
        self.assertEqual(tau, np.inf)  # removing everything also loses only ref 2


class SearchTest(unittest.TestCase):
    def test_largest_feasible_checks_every_candidate(self):
        self.assertEqual(T.largest_feasible(np.array([0.0, 2.0, 1.0]), 1.0), 2)
        self.assertEqual(T.largest_feasible(np.array([0.0, 2.0, 3.0]), 1.0), 0)
        self.assertIsNone(T.largest_feasible(np.array([2.0, 3.0]), 1.0))

    def test_step_function_equals_brute_force(self):
        rng = np.random.default_rng(5)
        for trial in range(25):
            mixes = [_random_mixture(rng) for _ in range(4)]
            steps, means_all = [], []
            for ref, ints, hyp, lab, means in mixes:
                b = T.evaluate_hyp(hyp, ref, ints, lab)
                u = T.unreachable(hyp, ref)
                fn = lambda kept, ref=ref, ints=ints, lab=lab, b=b, u=u: T.mix_counts(T.evaluate_hyp(kept, ref, ints, lab), b, u, False, False)
                steps.append(T.step_counts(hyp, means, fn))
                means_all.append(means)
            w = rng.integers(0, 3, len(mixes)).astype(float)
            cands, totals = T.pooled_steps(steps, w)
            expect_c = np.unique(np.concatenate(means_all + [np.array([np.inf])]))
            np.testing.assert_array_equal(cands, expect_c)
            for ci, tau in enumerate(cands):
                brute = sum(wi * T.mix_counts(T.evaluate_hyp([h for h, m in zip(hyp, means) if m >= tau], ref, ints, lab),
                                              T.evaluate_hyp(hyp, ref, ints, lab), T.unreachable(hyp, ref), False, False)
                            for wi, (ref, ints, hyp, lab, means) in zip(w, mixes))
                np.testing.assert_allclose(totals[ci], brute, rtol=0, atol=1e-9)
            # search_tau picks the largest candidate meeting the rule, by brute force.
            for rule in (T.budget_rule(0.1), T.matched_rule(0.05), T.matched_rule(-0.02)):
                ok = [bool(rule(totals[ci])) for ci in range(len(cands))]
                tau, j, _ = T.search_tau(steps, w, rule)
                if any(ok):
                    self.assertEqual(j, max(i for i, o in enumerate(ok) if o))
                    self.assertEqual(tau, cands[j])
                else:
                    self.assertIsNone(tau)
                    self.assertIsNone(j)

    def test_matched_s0_infeasible(self):
        # A clean S0 mixture: B is perfect, so no threshold can lower its WER.
        ref = [W("a", 0.0, 0.2), W("b", 0.3, 0.5)]
        lab = np.ones(60, np.uint8)
        b = T.evaluate_hyp(ref, ref, [], lab)
        fn = lambda kept: T.mix_counts(T.evaluate_hyp(kept, ref, [], lab), b, frozenset(), False, False)
        steps = [T.step_counts(list(ref), np.array([0.3, 0.6]), fn)]
        self.assertEqual(T.search_tau(steps, np.ones(1), T.matched_rule(0.0))[0], 0.3)  # keep everything: dWER 0
        tau, j, tot = T.search_tau(steps, np.ones(1), T.matched_rule(-0.001))
        self.assertIsNone(tau)
        self.assertIsNone(tot)

    def test_zero_weight_mixtures_still_supply_candidates(self):
        lab = np.ones(60, np.uint8)
        ref = [W("a", 0.0, 0.2)]
        b = T.evaluate_hyp(ref, ref, [], lab)
        fn = lambda kept: T.mix_counts(T.evaluate_hyp(kept, ref, [], lab), b, frozenset(), False, False)
        steps = [T.step_counts(list(ref), np.array([0.4]), fn), T.step_counts(list(ref), np.array([0.7]), fn)]
        cands, totals = T.pooled_steps(steps, np.array([1.0, 0.0]))
        np.testing.assert_array_equal(cands, [0.4, 0.7, np.inf])
        self.assertEqual(totals[1][T.COL["lost/single"]], 1)  # tau 0.7 removes mixture 0's token

    def test_tied_means_kept_at_tau(self):
        lab = np.ones(60, np.uint8)
        ref = [W("a", 0.0, 0.2), W("b", 0.3, 0.5)]
        b = T.evaluate_hyp(ref, ref, [], lab)
        fn = lambda kept: T.mix_counts(T.evaluate_hyp(kept, ref, [], lab), b, frozenset(), False, False)
        levels, counts = T.step_counts(list(ref), np.array([0.5, 0.5]), fn)
        np.testing.assert_array_equal(levels, [0.5])
        self.assertEqual(counts[0][T.COL["lost/single"]], 0)  # tau = 0.5 keeps both
        self.assertEqual(counts[1][T.COL["lost/single"]], 2)  # above: both removed

    def test_convention_inf_removes_all_min_keeps_all(self):
        lab = np.ones(60, np.uint8)
        ref = [W("a", 0.0, 0.2), W("b", 0.3, 0.5)]
        b = T.evaluate_hyp(ref, ref, [], lab)
        fn = lambda kept: T.mix_counts(T.evaluate_hyp(kept, ref, [], lab), b, frozenset(), False, False)
        cands, totals = T.pooled_steps([T.step_counts(list(ref), np.array([0.3, 0.6]), fn)], np.ones(1))
        self.assertEqual(cands[0], 0.3)
        self.assertEqual(T.summarize(totals[0])["coverage/all"], 1.0)  # min mean: everything kept
        self.assertEqual(cands[-1], np.inf)
        self.assertEqual(T.summarize(totals[-1])["coverage/all"], 0.0)  # +inf: everything removed


class BootstrapTest(unittest.TestCase):
    def test_draws_equal_compute_metrics(self):
        # evaluate.compute_metrics' exact construction (seed 0, bincount of integers).
        rng = np.random.default_rng(0)
        U, B = 7, 50
        want = [np.bincount(rng.integers(0, U, U), minlength=U).astype(np.float64) for _ in range(B)]
        got = T.boot_draws(U, B)
        self.assertEqual(got.shape, (B, U))
        for a, b in zip(want, got):
            np.testing.assert_array_equal(a, b)

    def test_weight_matrix_hand_computed(self):
        involved = [["1"], ["1", "2"], ["2", "3", "2"]]
        inv = M.involvement_matrix(involved, ["1", "2", "3"])
        draws = np.array([[2.0, 1.0, 0.0], [0.0, 3.0, 1.0]])
        Wm = T.boot_weights(inv, draws)
        np.testing.assert_array_equal(Wm, [[2.0, 2.0, 0.0], [0.0, 0.0, 3.0]])

    def test_ci_levels(self):
        v = np.arange(10001, dtype=float)
        self.assertEqual(T.ci(v), M.percentile_ci(v, 0.95))
        lo, hi = T.ci(v, T.BONFERRONI_LEVEL)
        self.assertAlmostEqual(T.BONFERRONI_LEVEL, 0.9875)
        self.assertAlmostEqual(lo, 62.5)
        self.assertAlmostEqual(hi, 9937.5)


class EvalwordsAgreementTest(unittest.TestCase):
    """tmetrics must reproduce W5's own stage-0 functions (evalwords at f6bea72,
    before evalwords was switched to import tmetrics): one set of definitions,
    not two that drift. The reference values are frozen in
    tests/fixtures/W0_tmetrics_evalwords_f6bea72.json, computed by that commit's
    evalwords (loaded from the git blob) on the inputs of `agreement_inputs`, so
    the check stays independent after the switch. The inputs' digest is pinned
    too: a change to the generator fails here instead of silently comparing
    other inputs."""

    @classmethod
    def setUpClass(cls):
        cls.ref = json.loads(FROZEN_EVALWORDS.read_text())
        cls.mix30, cls.cases = agreement_inputs()

    def test_inputs_unchanged(self):
        self.assertEqual(inputs_digest(self.mix30, self.cases), self.ref["inputs_sha256"])

    def test_per_mixture_and_summary_values(self):
        counts = []
        for (ref, ints, hyp, lab, mm), want in zip(self.mix30, self.ref["mix30"]["mixtures"]):
            x_hyp = [h for h, m in zip(hyp, mm) if m >= 0.5]
            b, x = T.evaluate_hyp(hyp, ref, ints, lab), T.evaluate_hyp(x_hyp, ref, ints, lab)
            u = T.unreachable(hyp, ref)
            self.assertEqual(sorted(x.correct), want["x_correct"])
            self.assertEqual(sorted(u), want["unreachable"])
            self.assertEqual([sum(x.S), sum(x.D), sum(x.I), sum(x.n_int), sum(x.n_other)], want["x_SDI_int_other"])
            counts.append(T.mix_counts(x, b, u, False, False))
        st = T.summarize(np.sum(counts, axis=0))
        for a, b in (("L+/all", "L+"), ("G/all", "G"), ("G_u/all", "G_u"), ("net_L/all", "net_L"), ("E/all", "E"),
                     ("WER/all", "WER"), ("R/all", "R"), ("other/all", "other_per_ref")):
            self.assertAlmostEqual(st[a], self.ref["mix30"]["summary"][b], places=12, msg=a)
        steps = [_b_steps(*m) for m in self.mix30]
        for want in self.ref["mix30"]["search"]:
            tau, _, tot = T.search_tau(steps, np.ones(len(steps)), T.budget_rule(want["budget"]))
            self.assertEqual(tau, float(want["tau"]))
            self.assertAlmostEqual(T.summarize(tot)["L+/all"], want["L+"], places=12)

    def test_search_tau_on_150_cases(self):
        # The reviewer's brute-forced check of W5's search_tau, frozen and repeated against tmetrics.
        for k, ((mixes, budget), want) in enumerate(zip(self.cases, self.ref["cases150"])):
            self.assertEqual(budget, want["budget"])
            steps = [_b_steps(*m) for m in mixes]
            tau, _, tot = T.search_tau(steps, np.ones(len(steps)), T.budget_rule(budget))
            self.assertEqual(tau, float(want["tau"]), msg=f"case {k}")
            self.assertAlmostEqual(T.summarize(tot)["L+/all"], want["L+"], places=12, msg=f"case {k}")


FROZEN_EVALWORDS = Path(__file__).resolve().parent / "fixtures" / "W0_tmetrics_evalwords_f6bea72.json"


def _b_steps(ref, ints, hyp, lab, mm):
    """Step function of a word filter on B's hypothesis (L+ relative to B)."""
    b, u = T.evaluate_hyp(hyp, ref, ints, lab), T.unreachable(hyp, ref)
    return T.step_counts(hyp, mm, lambda kept: T.mix_counts(T.evaluate_hyp(kept, ref, ints, lab), b, u, False, False))


def agreement_inputs():
    """The inputs of the frozen agreement fixture: 30 mixtures (seed 11) and 150
    multi-mixture threshold-search cases (seed 150), each with its budget."""
    rng = np.random.default_rng(11)
    mix30 = [_random_mixture(rng) for _ in range(30)]
    rng = np.random.default_rng(150)
    cases = []
    for _ in range(150):
        mixes = [_random_mixture(rng) for _ in range(int(rng.integers(1, 6)))]
        cases.append((mixes, float(rng.choice([0.005, 0.1, 0.3]))))
    return mix30, cases


def inputs_digest(mix30, cases) -> str:
    h = hashlib.sha256()

    def mix(m):
        ref, ints, hyp, lab, mm = m
        words = lambda ws: [[w.text, repr(w.start), repr(w.end)] for w in ws]
        h.update(json.dumps([words(ref), [words(r) for r in ints], words(hyp), [repr(float(v)) for v in mm]]).encode())
        h.update(np.ascontiguousarray(lab, dtype=np.uint8).tobytes())

    for m in mix30:
        mix(m)
    for mixes, budget in cases:
        h.update(repr(budget).encode())
        for m in mixes:
            mix(m)
    return h.hexdigest()


def _random_mixture(rng):
    """Words from a 3-word vocabulary (so repeats are common), B's hypothesis
    jittered from the reference with substitutions, deletions and insertions, one
    interferer, random labels and token means."""
    vocab = ["red", "blue", "green"]
    n = int(rng.integers(2, 7))
    t, ref = 0.0, []
    for _ in range(n):
        d = float(rng.uniform(0.1, 0.4))
        ref.append(W(str(rng.choice(vocab)), round(t, 3), round(t + d, 3)))
        t += d + float(rng.uniform(0.0, 0.6))
    ints = [[W(str(rng.choice(vocab)), round(float(s), 3), round(float(s) + 0.2, 3)) for s in sorted(rng.uniform(0, t, int(rng.integers(0, 3))))]]
    hyp = []
    for r in ref:
        u = rng.random()
        if u < 0.15:
            continue
        txt = r.text if u < 0.7 else str(rng.choice(vocab))
        j = float(rng.uniform(-0.3, 0.3))
        hyp.append(W(txt, round(max(0.0, r.start + j), 3), round(max(0.0, r.end + j), 3)))
    for w in ints[0]:
        if rng.random() < 0.6:
            hyp.append(W(w.text, w.start, w.end))
    if rng.random() < 0.5:
        s = float(rng.uniform(0, t))
        hyp.append(W(str(rng.choice(vocab)), round(s, 3), round(s + 0.15, 3)))
    hyp.sort(key=lambda w: w.start)
    lab = rng.integers(0, 4, int(np.ceil(t * 100)) + 50).astype(np.uint8)
    means = np.round(rng.random(len(hyp)), 1)  # coarse: ties between tokens are common
    return ref, ints, hyp, lab, means


if __name__ == "__main__":
    unittest.main()
