"""Contract tests for the word rule, tau calibration, bootstrap weights, AUC/EER
and the energy-gate baseline (synthetic arrays only)."""

import unittest

import numpy as np

from lfspk.harness import metrics as M
from lfspk.harness.baselines import EnergyGate, KeepEverything, gate_frames


def record(mid, tokens, n_ref=(4, 0), dels=(0, 0)):
    # token: (f0, f1, source, kind, op, op_region, region)
    return {"id": mid, "tokens": [["w", f0, f1, i, src, kind, 0, op, opr, reg, f0 / 100, f1 / 100] for i, (f0, f1, src, kind, op, opr, reg) in enumerate(tokens)],
            "n_ref": {"single": n_ref[0], "overlap": n_ref[1]}, "dels": {"single": dels[0], "overlap": dels[1]}}


class WordRuleTest(unittest.TestCase):
    def setUp(self):
        # Mixture 0: four correct target words, one interferer word, one other word.
        r0 = record("a", [(0, 10, "target", "C", "C", "single", "single"), (10, 20, "target", "C", "C", "single", "single"),
                          (20, 30, "target", "C", "C", "single", "single"), (30, 40, "target", "C", "C", "single", "single"),
                          (40, 50, "interferer", "C", "I", "single", "single"), (50, 60, "other", "I", "I", "single", "single")])
        # Mixture 1: two correct target words (one in overlap), one substitution, two interferer words, one deletion.
        r1 = record("b", [(0, 10, "target", "C", "C", "single", "single"), (10, 20, "target", "C", "C", "overlap", "overlap"),
                          (20, 30, "target", "S", "S", "single", "single"), (30, 40, "interferer", "C", "I", "overlap", "overlap"),
                          (40, 50, "interferer", "S", "I", "single", "single")], n_ref=(3, 1), dels=(1, 0))
        self.tok = M.build_tokens([r0, r1], ["S0", "S4"])
        self.scores = [np.repeat([0.9, 0.8, 0.7, 0.6, 0.1, 0.2], 10).astype(np.float32), np.repeat([0.95, 0.3, 0.5, 0.4, 0.05], 10).astype(np.float32)]
        self.means = M.token_means(self.tok, self.scores)

    def test_token_means(self):
        np.testing.assert_allclose(self.means, [0.9, 0.8, 0.7, 0.6, 0.1, 0.2, 0.95, 0.3, 0.5, 0.4, 0.05], rtol=1e-6)

    def test_keep_everything_is_unfiltered(self):
        s = M.summarize(self.tok, self.means, 0.0, np.ones(2))
        self.assertEqual(s["wer_before/all"], s["wer_after/all"])
        self.assertEqual(s["interferer_kept/all"], 1.0)
        self.assertEqual(s["target_removed/all"], 0.0)
        # errors: m0 I=2; m1 S=1, I=2, D=1 -> 6 errors / 8 reference words
        self.assertAlmostEqual(s["wer_before/all"], 6 / 8)

    def test_filtering_accounting(self):
        s = M.summarize(self.tok, self.means, 0.35, np.ones(2))
        # removed: m0 interferer (0.1), other (0.2); m1 overlap target C (0.3), interferer S (0.05)
        self.assertAlmostEqual(s["interferer_kept/all"], 1 / 3)  # only m1's 0.4 interferer kept
        self.assertAlmostEqual(s["target_removed/all"], 1 / 8)
        self.assertAlmostEqual(s["wer_after/all"], (6 - 3 + 1) / 8)  # three insertions gone, one C -> D
        self.assertAlmostEqual(s["target_removed/overlap"], 1 / 1)
        self.assertAlmostEqual(s["interferer_kept/overlap"], 1.0)
        self.assertAlmostEqual(s["other_kept/all"], 0.0)

    def test_calibration_respects_budget_and_is_maximal(self):
        led = M.Ledger(self.tok, self.means)
        # Budget of 0 words: tau may not exceed the lowest correct-target score (0.3).
        self.assertAlmostEqual(led.calibrate(np.ones(2), budget=0.0), 0.3)
        # 1/8 budget allows one correct target word: tau = second lowest (0.6).
        self.assertAlmostEqual(led.calibrate(np.ones(2), budget=1 / 8), 0.6)
        # Weights: drop mixture 1, budget 1/4 of 4 words = 1 word -> tau 0.7.
        self.assertAlmostEqual(led.calibrate(np.array([1.0, 0.0]), budget=0.25), 0.7)
        for b in (0.0, 0.1, 0.2, 0.5):
            t = led.calibrate(np.ones(2), budget=b)
            s = led.summarize(led.removed(t), np.ones(2))
            self.assertLessEqual(s["target_removed/all"], b + 1e-12)

    def test_weights_multiply_counts(self):
        s1 = M.summarize(self.tok, self.means, 0.35, np.array([1.0, 2.0]))
        # Mixture 1 counted twice: interferers kept 2 x 1 of 1 + 2 x 2.
        self.assertAlmostEqual(s1["interferer_kept/all"], (0 + 2 * 1) / (1 + 2 * 2))


class CalibrationEdgeTest(unittest.TestCase):
    def test_degenerate_calibration(self):
        # Eval r1 #4 as decided after r2: all candidates within budget -> tau just
        # above the highest candidate (finite); no candidate -> uncalibrated (NaN).
        r = record("a", [(0, 10, "target", "C", "C", "single", "single"), (10, 20, "interferer", "C", "I", "single", "single")], n_ref=(200, 0))
        tok = M.build_tokens([r], ["S4"])
        led = M.Ledger(tok, np.array([0.2, 0.8]))
        t = led.calibrate(np.ones(1))
        self.assertTrue(0.2 < t < 0.2 + 1e-12)
        r2 = record("b", [(0, 10, "interferer", "C", "I", "single", "single")], n_ref=(5, 0))
        led2 = M.Ledger(M.build_tokens([r2], ["S4"]), np.array([0.9]))
        self.assertTrue(np.isnan(led2.calibrate(np.ones(1))))
        self.assertTrue(np.isnan(led.calibrate(np.zeros(1))))

    def test_ambiguous_and_coverage(self):
        # A token exactly matched by both the target and an interferer.
        r = {"id": "a", "tokens": [["go", 0, 10, 0, "target", "C", -1, "C", "single", "single", 0.0, 0.1, True],
                                   ["x", 10, 20, 1, "interferer", "C", 0, "I", "single", "single", 0.1, 0.2, False],
                                   ["y", 20, 30, 2, "target", "S", -1, "S", "single", "single", 0.2, 0.3, False]],
             "n_ref": {"single": 4, "overlap": 0}, "dels": {"single": 2, "overlap": 0}}
        tok = M.build_tokens([r], ["S4"])
        s = M.summarize(tok, np.array([0.9, 0.1, 0.9]), 0.5, np.ones(1))
        self.assertEqual(s["interferer_kept/all"], 0.0)
        self.assertAlmostEqual(s["interferer_kept_incl_ambiguous/all"], 0.5)  # the ambiguous token is kept
        self.assertEqual(s["n_ambiguous/all"], 1.0)
        # Counted whichever source won the attribution (eval r2 #5).
        r["tokens"][0][4] = "interferer"
        s2 = M.summarize(M.build_tokens([r], ["S4"]), np.array([0.9, 0.1, 0.9]), 0.5, np.ones(1))
        self.assertEqual(s2["n_ambiguous/all"], 1.0)
        self.assertAlmostEqual(s["target_coverage/all"], 0.25)


class BootstrapTest(unittest.TestCase):
    def test_joint_weights(self):
        inv = M.involvement_matrix([["a"], ["a", "b"], ["b", "c"]], ["a", "b", "c"])
        w = M.weights_from_counts(inv, np.array([2.0, 0.0, 1.0]))
        np.testing.assert_array_equal(w, [2.0, 0.0, 0.0])
        w = M.weights_from_counts(inv, np.array([1.0, 3.0, 1.0]))
        np.testing.assert_array_equal(w, [1.0, 3.0, 3.0])
        self.assertEqual(inv.shape, (3, 2))
        self.assertEqual(inv[0].tolist(), [0, -1])

    def test_speaker_weights_expectation(self):
        rng = np.random.default_rng(0)
        ws = np.array([M.speaker_weights([["a"], ["a", "b"]], ["a", "b", "c", "d"], rng) for _ in range(4000)])
        self.assertAlmostEqual(ws[:, 0].mean(), 1.0, delta=0.05)  # E[count] = 1
        self.assertAlmostEqual(ws[:, 1].mean(), 1 - 1 / 4, delta=0.05)  # E[c_a c_b] = 1 - 1/n

    def test_percentile_ci(self):
        lo, hi = M.percentile_ci(np.arange(1001.0))
        self.assertAlmostEqual(lo, 25.0)
        self.assertAlmostEqual(hi, 975.0)


class FrameMetricTest(unittest.TestCase):
    def test_auc_eer_exact(self):
        labels = np.array([1] * 50 + [2] * 50 + [0] * 10 + [3] * 10)
        perfect = np.where((labels == 1) | (labels == 3), 0.9, 0.1).astype(np.float32)
        self.assertEqual(M.exact_auc_eer(perfect, labels), (1.0, 0.0))
        const = np.full(labels.size, 0.5, np.float32)
        auc, eer = M.exact_auc_eer(const, labels)
        self.assertAlmostEqual(auc, 0.5)
        self.assertAlmostEqual(eer, 0.5)
        from sklearn.metrics import roc_auc_score

        rng = np.random.default_rng(0)
        noisy = np.clip(perfect + rng.normal(0, 0.3, labels.size), 0, 1).astype(np.float32)
        sel = labels != 0
        self.assertAlmostEqual(M.exact_auc_eer(noisy, labels)[0], roc_auc_score(labels[sel] != 2, noisy[sel]), places=10)

    def test_saturated_scores_keep_their_order(self):
        # Review eval r1 #1: 0.9999 vs 0.999 must not collapse into one bin.
        labels = [np.array([1, 1, 2, 2]), np.array([3, 2])]
        scores = [np.array([0.9999, 0.9999, 0.999, 0.999], np.float32), np.array([0.9999, 0.999], np.float32)]
        fr = M.FrameRanks(scores, labels)
        self.assertEqual(fr.auc_eer(), (1.0, 0.0))
        auc, eer = fr.auc_eer(np.array([2.0, 0.0]))
        self.assertEqual((auc, eer), (1.0, 0.0))
        self.assertTrue(np.isnan(fr.auc_eer(np.array([0.0, 0.0]))[0]))

    def test_eer_interpolates_the_crossing(self):
        # Review eval r1 #3: pos [0.9, 0.1], neg [0.5] -> EER 0.5.
        fr = M.FrameRanks([np.array([0.9, 0.1, 0.5])], [np.array([1, 1, 2])])
        self.assertAlmostEqual(fr.auc_eer()[1], 0.5)
        fr = M.FrameRanks([np.array([0.9, 0.8, 0.7, 0.1])], [np.array([1, 1, 2, 2])])
        self.assertEqual(fr.auc_eer(), (1.0, 0.0))


class BaselineTest(unittest.TestCase):
    def test_keep_everything(self):
        k = KeepEverything()
        p = k.enroll([np.zeros(160, np.float32)])
        s = k.score(p, np.zeros(161, np.float32))
        self.assertEqual(s.tolist(), [1.0, 1.0])
        self.assertEqual(p.to_bytes(), b"")

    def test_energy_gate_semantics(self):
        rng = np.random.default_rng(0)
        quiet = (rng.standard_normal(16000) * 10 ** (-60 / 20)).astype(np.float32)  # -60 dBFS
        loud = (rng.standard_normal(8000) * 10 ** (-25 / 20)).astype(np.float32)  # -25 dBFS
        x = np.concatenate([quiet, loud, quiet])
        g = gate_frames(x)
        self.assertEqual(g.size, 250)
        self.assertFalse(g[:100].any())  # floor clamps at -70; -60 dB never rises 10 dB above it
        self.assertTrue(g[100:150].all())
        self.assertFalse(g[150:].any())
        self.assertFalse(gate_frames(np.zeros(1600, np.float32)).any())  # digital silence
        # A level more than 10 dB over a learned floor starts speech below -30 dB.
        floor = (rng.standard_normal(32000) * 10 ** (-65 / 20)).astype(np.float32)
        soft = (rng.standard_normal(4000) * 10 ** (-50 / 20)).astype(np.float32)
        g2 = gate_frames(np.concatenate([floor, soft]))
        self.assertTrue(g2[205:].all())
        sc = EnergyGate()
        self.assertEqual(sc.score(sc.enroll([x]), x).dtype, np.float32)


if __name__ == "__main__":
    unittest.main()


class WideningTest(unittest.TestCase):
    def test_word_in_pause_reaches_speech_when_widened(self):
        # Contract amendment 2026-10-21: a correct target word whose Parakeet span
        # lies in a labelled pause scores 0 for the oracle unwidened, but its
        # 80 ms-widened span reaches the speech, so the oracle keeps it.
        from lfspk.harness.align import decision_span

        lab = np.zeros(300, np.uint8)
        lab[:100] = 1
        oracle = ((lab == 1) | (lab == 3)).astype(np.float32)
        f0, f1 = decision_span(1.02, 1.06, 300)
        r = {"id": "a", "tokens": [["w", f0, f1, 0, "target", "C", -1, "C", "single", "single", 1.02, 1.06, False]],
             "n_ref": {"single": 1000, "overlap": 0}, "dels": {"single": 0, "overlap": 0}}
        tok = M.build_tokens([r], ["S0"])
        widened = M.token_means(tok, [oracle])[0]
        raw = M.token_means(M.rewiden(tok, 0.0, [300]), [oracle])[0]
        self.assertEqual(raw, 0.0)
        self.assertGreater(widened, 0.0)
        led = M.Ledger(tok, np.array([widened]))
        s = led.summarize(led.removed(0.25), np.ones(1))
        self.assertEqual(s["target_removed/all"], 0.0)  # kept at a threshold the raw span would fail
