"""W1 Stage A contracts on synthetic data: audio gate, protocol, metrics,
normalisation."""

import unittest
from pathlib import Path

import numpy as np

from lfspk import splits
from lfspk.api import frame_count
from lfspk.embed import audio as A
from lfspk.embed import metrics as M
from lfspk.embed import norm as N
from lfspk.embed import protocol as P


def _burst(n_total, start, stop, amp=0.3, noise=1e-4, seed=0):
    rng = np.random.default_rng(seed)
    x = (rng.standard_normal(n_total) * noise).astype(np.float32)
    t = np.arange(stop - start) / 16000
    x[start:stop] += (amp * np.sin(2 * np.pi * 220 * t)).astype(np.float32)
    return x


class AudioTest(unittest.TestCase):
    def test_energy_frames_follow_contract_framing(self):
        for n in (0, 1, 160, 161, 16000):
            self.assertEqual(A.frame_energy_db(np.zeros(n, np.float32)).size, frame_count(n))

    def test_partial_frame_uses_its_own_samples(self):
        x = np.zeros(170, np.float32)
        x[160:] = 0.5  # last partial frame: 10 samples at 0.5
        e = A.frame_energy_db(x)
        self.assertAlmostEqual(float(e[1]), 10 * np.log10(0.25), places=3)

    def test_gate_finds_burst(self):
        x = _burst(32000, 12000, 20000)
        g = A.speech_gate(A.frame_energy_db(x))
        self.assertTrue(g[80:120].all())  # frames 75-125 hold the burst
        self.assertFalse(g[:60].any())
        self.assertFalse(g[140:].any())


class GateContinuousSpeechTest(unittest.TestCase):
    def test_speech_without_pauses_passes(self):
        x = _burst(16000, 0, 16000)
        self.assertGreater(A.speech_gate(A.frame_energy_db(x)).mean(), 0.9)

    def test_gate_preserves_length_for_short_inputs(self):
        for e in ([-100.0, -20.0], [-20.0], [-20.0] * 3):
            self.assertEqual(A.speech_gate(np.array(e, np.float32)).shape, (len(e),))

    def test_uncapped_gate_keeps_noise_floor_threshold(self):
        rng = np.random.default_rng(4)
        x = (rng.standard_normal(160000) * 0.01).astype(np.float32)
        x[80000:84800] += 0.3
        g = A.speech_gate(A.frame_energy_db(x), A.GateConfig(peak_gap_db=None))
        self.assertLess(g.mean(), 0.1)
        self.assertTrue(g[505:525].all())

    def test_digital_silence_never_speech(self):
        self.assertFalse(A.speech_gate(A.frame_energy_db(np.zeros(16000, np.float32))).any())


class ProtocolTest(unittest.TestCase):
    spk = splits.Speaker("1", "F", "dev-clean")

    @staticmethod
    def _paths(chapters):
        return [Path(f"/x/1/{c}/1-{c}-{i:04d}.flac") for c, n in chapters for i in range(n)]

    def test_cross_project_holds_out_last_chapters_project(self):
        projects = {"10": "A", "20": "B", "30": "A", "40": "B"}
        p = P.plan_speaker(self.spk, self._paths([(20, 25), (10, 20), (30, 7), (40, 3)]), projects)
        self.assertEqual(p.relation, P.CROSS_PROJECT)
        self.assertEqual({P.chapter_of(u) for u in p.test}, {"20", "40"})
        self.assertEqual([P.chapter_of(u) for u in p.enroll], ["10"] * 20 + ["30"] * 7)
        self.assertTrue(set(p.enroll).isdisjoint(p.test))

    def test_same_project_holds_out_last_chapter(self):
        projects = {"10": "A", "20": "A", "30": "A"}
        p = P.plan_speaker(self.spk, self._paths([(20, 25), (10, 20), (30, 7)]), projects)
        self.assertEqual(p.relation, P.SAME_PROJECT)
        self.assertEqual({P.chapter_of(u) for u in p.test}, {"30"})
        self.assertEqual(len(p.enroll), 30)
        self.assertEqual([P.chapter_of(u) for u in p.enroll[:20]], ["10"] * 20)

    def test_single_chapter_splits_by_order(self):
        p = P.plan_speaker(self.spk, self._paths([(5, 40)]), {"5": "A"})
        self.assertEqual(p.relation, P.SAME_CHAPTER)
        self.assertEqual(len(p.enroll), 30)
        self.assertEqual(len(p.test), 10)
        self.assertEqual(p.enroll[-1].stem, "1-5-0029")

    def test_test_split_is_sealed(self):
        with self.assertRaises(PermissionError):
            P.plan("test")

    def test_segment_prefers_speech_and_is_reproducible(self):
        x = _burst(5 * 16000, 3 * 16000, 4 * 16000)
        s1 = P.place_segment(x, 0.5, P.segment_rng(0, "1-2-3", 0.5))
        s2 = P.place_segment(x, 0.5, P.segment_rng(0, "1-2-3", 0.5))
        self.assertEqual(s1, s2)
        start, n, ok = s1
        self.assertTrue(ok)
        self.assertEqual(n, 8000)
        self.assertGreaterEqual(start, 3 * 16000 - 4000)
        self.assertLessEqual(start + n, 4 * 16000 + 4000)
        self.assertNotEqual(P.segment_rng(1, "1-2-3", 0.5).integers(1 << 30),
                            P.segment_rng(0, "1-2-3", 0.5).integers(1 << 30))

    def test_short_clip_returned_whole(self):
        self.assertEqual(P.place_segment(np.zeros(4000, np.float32), 0.5, np.random.default_rng(0)), (0, 4000, True))

    def test_sparse_speech_in_noise_is_found(self):
        """Reviewer's case: 0.3 s of speech in 10 s of stationary noise. The
        capped gate marks everything as speech; placement must not."""
        rng = np.random.default_rng(4)
        x = (rng.standard_normal(160000) * 0.01).astype(np.float32)
        t = np.arange(4800) / 16000
        x[80000:84800] += (0.3 * np.sin(2 * np.pi * 220 * t)).astype(np.float32)
        for seed in range(3):
            start, n, ok = P.place_segment(x, 0.5, P.segment_rng(seed, "1-2-3", 0.5))
            overlap = max(0, min(start + n, 84800) - max(start, 80000))
            self.assertTrue(ok)
            self.assertGreaterEqual(overlap, 0.4 * n)


class MetricsTest(unittest.TestCase):
    def test_eer_hand_computed(self):
        s = [0.9, 0.8, 0.3, 0.5, 0.2, 0.1, 0.0]
        lab = [1, 1, 1, 0, 0, 0, 0]
        self.assertAlmostEqual(M.eer(s, lab), 0.25)

    def test_eer_extremes(self):
        self.assertAlmostEqual(M.eer([2, 3, 0, 1], [1, 1, 0, 0]), 0.0)
        self.assertAlmostEqual(M.eer([0, 1, 2, 3], [1, 1, 0, 0]), 1.0)
        self.assertAlmostEqual(M.eer([1, 1, 1, 1], [1, 1, 0, 0]), 0.5)  # ties

    def test_weights_equal_duplication(self):
        rng = np.random.default_rng(0)
        s = rng.standard_normal(50)
        lab = rng.random(50) < 0.3
        w = rng.integers(1, 4, 50)
        dup_s, dup_l = np.repeat(s, w), np.repeat(lab, w)
        self.assertAlmostEqual(M.eer(s, lab, w), M.eer(dup_s, dup_l))
        self.assertAlmostEqual(M.min_dcf(s, lab, 0.05, w), M.min_dcf(dup_s, dup_l, 0.05))

    def test_min_dcf(self):
        # p = 0.5: normalised DCF = fnr + fpr; best threshold here gives 0 + 0.25.
        s = [0.9, 0.8, 0.7, 0.5, 0.75, 0.1, 0.0]
        lab = [1, 1, 1, 0, 0, 0, 0]
        self.assertAlmostEqual(M.min_dcf(s, lab, 0.5), 0.25)
        self.assertLessEqual(M.min_dcf(s, lab, 0.01), 1.0)

    def test_fpr_at_fnr(self):
        # targets 0.9 0.8 0.3; non-targets 0.5 0.2 0.1 0.0. ROC (fnr, fpr):
        # (0,1) (0,.75) (0,.5) (0,.25) (1/3,.25) (1/3,0) (2/3,0) (1,0)
        roc = M.SortedTrials([0.9, 0.8, 0.3, 0.5, 0.2, 0.1, 0.0], [1, 1, 1, 0, 0, 0, 0]).roc()
        self.assertAlmostEqual(M.fpr_at_fnr_from_roc(roc, 0.0), 0.25)  # best with no miss
        self.assertAlmostEqual(M.fpr_at_fnr_from_roc(roc, 1 / 3), 0.0)  # plateau: keep rejecting impostors
        self.assertAlmostEqual(M.fpr_at_fnr_from_roc(roc, 1 / 6), 0.25)
        self.assertAlmostEqual(M.fpr_at_fnr_from_roc(roc, 1.0), 0.0)

    def test_fpr_at_fnr_plateau_regression(self):
        """Reviewer's case: one target at 0, 199 at 2, impostors at 1. A
        threshold of 1.5 misses exactly 0.5 % of targets and passes no impostor."""
        s = np.r_[0.0, np.full(199, 2.0), np.full(100, 1.0)]
        lab = np.r_[np.ones(200, bool), np.zeros(100, bool)]
        self.assertAlmostEqual(M.fpr_at_fnr_from_roc(M.SortedTrials(s, lab).roc(), 0.005), 0.0)

    def test_fpr_at_fnr_interpolates_between_points(self):
        roc = M.Roc(np.array([0.0, 0.02]), np.array([0.6, 0.2]))
        self.assertAlmostEqual(M.fpr_at_fnr_from_roc(roc, 0.01), 0.4)

    def test_trial_weights_rule(self):
        mult = np.array([2, 0, 3])
        w = M.trial_weights(mult, np.array([0, 0, 0, 2, 1]), np.array([0, 2, 1, 2, 0]))
        np.testing.assert_array_equal(w, [2, 6, 0, 3, 0])

    def test_trial_weights_with_extra_identity(self):
        mult = np.array([2, 0, 3, 5])
        model = np.array([0, 0, 0, 0, 2])
        test = np.array([0, 3, 2, 1, 2])
        extra = np.array([3, 3, 3, 3, -1])  # speaker 3's dictations entered speaker 0's profile
        # target 0: m0*m3 = 10; vs 3 (the extra itself): m0*m3 = 10; vs 2: m0*m2*m3 = 30; vs 1: 0; target 2: 3
        np.testing.assert_array_equal(M.trial_weights(mult, model, test, extra), [10, 10, 30, 0, 3])

    def test_multiplicities(self):
        m = M.speaker_multiplicities(40, 5, 1)
        self.assertEqual(m.shape, (5, 40))
        self.assertTrue((m.sum(axis=1) == 40).all())
        np.testing.assert_array_equal(m, M.speaker_multiplicities(40, 5, 1))

    def test_bootstrap_identity_replicates_equal_point(self):
        rng = np.random.default_rng(1)
        ms = np.repeat(np.arange(4), 20)
        ts = np.tile(np.repeat(np.arange(4), 5), 4)
        lab = ms == ts
        s = rng.standard_normal(ms.size) + 2 * lab
        est, reps = M.bootstrap(M.eer_from_roc, s, lab, ms, ts, np.ones((3, 4), int))
        np.testing.assert_allclose(reps, est.value)
        self.assertAlmostEqual(est.value, M.eer(s, lab))


class BootstrapMultiTest(unittest.TestCase):
    def test_matches_single_metric_bootstrap(self):
        rng = np.random.default_rng(2)
        ms = np.repeat(np.arange(6), 30)
        ts = np.tile(np.repeat(np.arange(6), 5), 6)
        lab = ms == ts
        s = rng.standard_normal(ms.size) + 1.5 * lab
        mults = M.speaker_multiplicities(6, 50, 3)
        one, reps = M.bootstrap(M.eer_from_roc, s, lab, ms, ts, mults)
        multi = M.bootstrap_multi({"eer": M.eer_from_roc}, s, lab, ms, ts, mults)
        self.assertEqual(multi["eer"][0], one)
        np.testing.assert_array_equal(multi["eer"][1], reps)


class NormTest(unittest.TestCase):
    def setUp(self):
        rng = np.random.default_rng(0)
        u = rng.standard_normal((30, 8))
        self.u = u / np.linalg.norm(u, axis=1, keepdims=True)

    def test_raw_is_cosine(self):
        np.testing.assert_allclose(N.score_matrix(self.u[:3], self.u[3:6]), self.u[:3] @ self.u[3:6].T)

    def test_top_k_uses_largest(self):
        cohort = self.u[10:]
        mu, sd = N.cohort_stats(self.u[:2], cohort, top_k=5)
        s = self.u[:2] @ cohort.T
        top = np.sort(s, axis=1)[:, -5:]
        np.testing.assert_allclose(mu, top.mean(1))
        np.testing.assert_allclose(sd, top.std(1))
        with self.assertRaises(ValueError):
            N.cohort_stats(self.u[:2], cohort, top_k=0)

    def test_snorm_formula(self):
        cohort = self.u[10:]
        S = N.score_matrix(self.u[:2], self.u[2:5], cohort_profile=cohort, cohort_test=cohort, top_k=7)
        me, se = N.cohort_stats(self.u[:2], cohort, 7)
        mt, st = N.cohort_stats(self.u[2:5], cohort, 7)
        raw = self.u[:2] @ self.u[2:5].T
        want = 0.5 * ((raw - me[:, None]) / se[:, None] + (raw - mt[None]) / st[None])
        np.testing.assert_allclose(S, want)
        with self.assertRaises(ValueError):
            N.score_matrix(self.u[:2], self.u[2:5], cohort_profile=cohort)


if __name__ == "__main__":
    unittest.main()


class SurveyScoreIntegrationTest(unittest.TestCase):
    """`survey score` runs from committed sources on a synthetic embedding cache
    (random unit vectors over the real dev plan), without W0's halves module."""

    @unittest.skipUnless((splits.paths.LIBRISPEECH / "dev-clean").is_dir(), "needs the dev file lists")
    def test_scores_without_halves(self):
        import argparse
        import csv
        import json
        import sys
        import tempfile
        from unittest import mock

        from lfspk.embed import survey as SV

        rng = np.random.default_rng(0)
        dim = 8

        def unit(n):
            v = rng.standard_normal((n, dim)).astype(np.float32)
            return v / np.linalg.norm(v, axis=1, keepdims=True)

        def write(d, stem, rows):
            np.save(d / f"{stem}.f32.npy", unit(len(rows)))
            with open(d / f"{stem}.tsv", "w", newline="") as f:
                w = csv.DictWriter(f, fieldnames=list(rows[0]), delimiter="\t")
                w.writeheader()
                w.writerows(rows)

        plans = P.plan("dev")
        with tempfile.TemporaryDirectory() as tmp, \
                mock.patch.object(SV, "LENGTHS", (1.0,)), mock.patch.object(SV, "KS", (10,)), \
                mock.patch.object(SV, "TOP_KS", (50,)), mock.patch.dict(sys.modules, {"lfspk.harness.halves": None}):
            d = Path(tmp) / "emb" / "fake"
            d.mkdir(parents=True)
            full, seg = [], []
            for p in plans:
                tests = {P.utt_id(u) for u in p.test}
                for u in sorted(p.enroll + p.test):
                    full.append({"utt": P.utt_id(u), "speaker": p.speaker.id, "sex": p.speaker.sex,
                                 "chapter": P.chapter_of(u), "pool": "test" if P.utt_id(u) in tests else "enroll"})
                    if P.utt_id(u) in tests:
                        seg += [{"utt": P.utt_id(u), "speaker": p.speaker.id, "len_s": 1.0, "seed": sd}
                                for sd in P.SEEDS]
            write(d, "dev_full", full)
            write(d, "dev_seg", seg)
            cohort = [{"utt": f"{9000 + i // 2}-{i // 4}-{i:04d}", "speaker": str(9000 + i // 2)} for i in range(120)]
            write(d, "cohort_full", cohort)
            write(d, "cohort_seg", [dict(r, len_s=1.0) for r in cohort])
            (d / "meta.json").write_text(json.dumps({"embedder": "fake", "params": 0}))
            import contextlib
            import io

            with contextlib.redirect_stdout(io.StringIO()):
                SV.cmd_score(argparse.Namespace(embedders=["fake"], n_boot=3, boot_seed=1, out=tmp, smoke=True,
                                                accept_embed_provenance=[]))
                SV.cmd_render(argparse.Namespace(out=tmp))
            import shutil

            shutil.copytree(d, Path(tmp) / "emb" / "fake2")
            with contextlib.redirect_stdout(io.StringIO()):  # r5: compare without halves, all-speaker only
                SV.cmd_compare(argparse.Namespace(pairs=["fake:fake2"], n_boot=3, boot_seed=1, out=tmp, smoke=True,
                                                  accept_embed_provenance=[], provenance_reason=""))
            comp = json.loads((Path(tmp) / "results" / "compare.json").read_text())
            self.assertIn("halves module unavailable", comp["incomplete"])
            self.assertIn("fake-fake2|1.0|k10|raw|all|eer", comp["pairs"])
            self.assertFalse(any("halfB" in k for k in comp["pairs"]))
            res = json.loads((Path(tmp) / "results" / "intrinsic.json").read_text())["embedders"]["fake"]
            report = (Path(tmp) / "results" / "intrinsic.md").read_text()
        self.assertTrue(report.startswith("**SMOKE RUN, NOT A RESULT: fake.**"))
        self.assertIn("**INCOMPLETE: selection-aware half analysis skipped", report)
        self.assertTrue(res["smoke"])
        self.assertFalse(res["halves_available"])
        self.assertEqual(len(res["speakers"]), len(plans))
        self.assertIn("1.0|k10|raw|all", res["ci"])
        self.assertIn("1.0|k10|asnorm50|cross_project", res["point"])
        self.assertFalse(any("half" in k for k in res["point"]))
        eer = res["point"]["1.0|k10|raw|all"]["eer"]
        self.assertGreater(eer, 0.35)  # random embeddings: chance level
