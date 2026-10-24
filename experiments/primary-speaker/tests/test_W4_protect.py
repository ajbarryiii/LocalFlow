"""W4 contracts on synthetic arrays: metrics, roles, protections, attackers, cache."""

from __future__ import annotations

import math
import tempfile
import unittest
from pathlib import Path

import numpy as np

from lfspk.protect import attacks, embcache, metrics, roles, transforms
from lfspk.protect.transforms import GRID, build, l2n

D = 24


def synth_speakers(n_spk: int, per: int, seed: int, spread: float = 0.35, d: int = D):
    """Unit embeddings: speaker mean + isotropic noise. Speaker ids are digit strings."""
    rng = np.random.default_rng(seed)
    means = l2n(rng.standard_normal((n_spk, d)) + 0.8)  # non-zero global mean, like real embedders
    X, y = [], []
    for i in range(n_spk):
        X.append(l2n(means[i] + spread * rng.standard_normal((per, d)) / math.sqrt(d) * 3))
        y += [str(1000 + i)] * per
    return np.vstack(X), np.array(y), means


class MetricsTest(unittest.TestCase):
    def test_eer_separable_and_inverted(self):
        s = np.array([0.1, 0.2, 0.8, 0.9])
        lab = np.array([0, 0, 1, 1])
        e, t = metrics.eer(s, lab)
        self.assertEqual(e, 0.0)
        self.assertTrue(0.2 < t <= 0.8)
        e2, _ = metrics.eer(-s, lab)
        self.assertEqual(e2, 1.0)

    def test_eer_known_value(self):
        # 4 targets, 4 non-targets, one of each on the wrong side: EER 0.25
        s = np.array([0.9, 0.8, 0.7, 0.3, 0.6, 0.2, 0.1, 0.05])
        lab = np.array([1, 1, 1, 1, 0, 0, 0, 0])
        self.assertAlmostEqual(metrics.eer(s, lab)[0], 0.25)

    def test_eer_ties_not_split(self):
        s = np.zeros(10)
        lab = np.array([1] * 5 + [0] * 5)
        self.assertAlmostEqual(metrics.eer(s, lab)[0], 0.5)

    def test_min_dcf_bounds(self):
        rng = np.random.default_rng(0)
        lab = rng.integers(0, 2, 500)
        self.assertEqual(metrics.min_dcf(lab.astype(float), lab), 0.0)
        d = metrics.min_dcf(rng.random(500), lab)
        self.assertTrue(0.0 <= d <= 1.0 + 1e-9)

    def test_threshold_at_far(self):
        non = np.arange(100, dtype=float)
        t = metrics.threshold_at_far(non, 0.05)
        self.assertLessEqual(np.mean(non >= t), 0.05)
        self.assertGreater(np.mean(non >= t - 1), 0.05)  # the smallest such threshold
        w = np.random.default_rng(0).integers(0, 3, 100)
        rep = np.repeat(non, w)
        self.assertEqual(metrics.threshold_at_far(non, 0.05, w), metrics.threshold_at_far(rep, 0.05))
        self.assertGreater(metrics.threshold_at_far(non, 0.0), non.max())
        # r3 #2: 99 scores in [0.1, 0.2] and one at 0.9: FAR 1 % is met just
        # above 0.2, so a clone scoring 0.8 must be accepted
        non2 = np.r_[np.linspace(0.1, 0.2, 99), 0.9]
        t2 = metrics.threshold_at_far(non2, 0.01)
        self.assertLessEqual(np.mean(non2 >= t2), 0.01)
        self.assertTrue(0.2 < t2 <= 0.8)
        # weighted version agrees with replication
        self.assertEqual(metrics.threshold_at_far(non2, 0.01, np.full(100, 3)),
                         metrics.threshold_at_far(np.repeat(non2, 3), 0.01))

    def test_wsr_bounds(self):
        rng = np.random.default_rng(0)
        # valid direction: upper >= sample mean >= lower
        for _ in range(20):
            x = rng.random(40)
            self.assertGreaterEqual(metrics.wsr_upper_mean(x, grid=400), x.mean() - 1e-9)
            self.assertLessEqual(metrics.wsr_lower_mean(x, grid=400), x.mean() + 1e-9)
        # invert-r4 counterexample sample: every target at 2/20, floor 0 -> above 0.10
        self.assertGreaterEqual(metrics.delta_upper(np.full(73, 0.1), np.zeros(73)), 0.10)
        # all-zero data on 73 targets: the resolution limit, between 0.05 and 0.10
        z = metrics.delta_upper(np.zeros(73), np.zeros(73))
        self.assertTrue(0.05 < z < 0.10, z)
        # coverage spot check: true mean 0.1, 200 samples of 73 binomial rates
        miss = sum(metrics.wsr_upper_mean(rng.binomial(20, 0.1, 73) / 20, 0.025, grid=400) < 0.1
                   for _ in range(200))
        self.assertLessEqual(miss, 10)

    def test_wsr_rounds_outward(self):
        # invert-r5 #3: grid inversion must not round inward
        self.assertGreaterEqual(metrics.wsr_upper_mean(np.full(73, 0.9999)), 0.9999)
        x = np.random.default_rng(27).binomial(20, 0.03, size=(41, 73))[40] / 20
        self.assertGreater(metrics.delta_upper(x, np.zeros(73)), 0.10)
        # floors above zero lower the bound: the resolution table is not universal
        self.assertLess(metrics.delta_upper(np.zeros(73), np.full(73, 0.05)), 0.05)

    def test_target_order_is_a_fixed_permutation(self):
        spk = [str(i) for i in (30, 4, 1000, 7, 12)]
        o1 = metrics.target_order(spk, 3)
        self.assertEqual(sorted(o1.tolist()), list(range(5)))
        np.testing.assert_array_equal(o1, metrics.target_order(list(reversed(spk))[::-1], 3))
        self.assertFalse(np.array_equal(o1, metrics.target_order(spk, 4)) and
                         np.array_equal(o1, np.argsort([int(x) for x in spk])))

    def test_clopper_pearson(self):
        self.assertAlmostEqual(metrics.clopper_pearson_upper(0, 73), 1 - 0.05 ** (1 / 73), places=6)
        self.assertGreater(metrics.clopper_pearson_upper(0, 73), 0.02)  # 'negligible' unreachable on dev
        self.assertLess(metrics.clopper_pearson_upper(0, 73), 0.05)
        self.assertEqual(metrics.clopper_pearson_upper(5, 5), 1.0)
        self.assertGreater(metrics.clopper_pearson_upper(3, 73), 3 / 73)

    def test_id_rank(self):
        g = np.eye(3)
        q = np.array([[1, 0.1, 0], [0.2, 0, 1.0]])
        np.testing.assert_array_equal(metrics.id_rank(q, g, [0, 0]), [1, 2])

    def test_weighted_eer_equals_replicated_trials(self):
        rng = np.random.default_rng(3)
        sc = rng.standard_normal(60)
        lab = rng.integers(0, 2, 60)
        w = rng.integers(0, 4, 60)
        rep = np.repeat(np.arange(60), w)
        self.assertAlmostEqual(metrics.eer(sc, lab, w)[0], metrics.eer(sc[rep], lab[rep])[0])
        self.assertAlmostEqual(metrics.min_dcf(sc, lab, weights=w), metrics.min_dcf(sc[rep], lab[rep]))

    def test_joint_weights(self):
        owner = np.array([0, 0, 1, 2])
        other = np.array([0, 1, 2, 2])
        counts = np.array([2, 0, 3])
        np.testing.assert_array_equal(metrics.joint_multiplicity_weights(owner, other, counts), [2, 0, 0, 3])

    def test_joint_bootstrap_wider_than_enrollment_only(self):
        # A few probe speakers ("wolves") score high against every profile.
        # Resampling only profiles keeps every wolf in every resample and hides
        # that variance; the joint bootstrap must show it.
        rng = np.random.default_rng(0)
        n = 30
        wolf = np.where(np.arange(n) < 3, 1.2, 0.0)
        owner = np.repeat(np.arange(n), n)
        other = np.tile(np.arange(n), n)
        lab = owner == other
        sc = np.where(lab, 1.0, wolf[other]) + 0.3 * rng.standard_normal(n * n)
        fn = lambda w: metrics.eer(sc, lab, w)[0]
        _, lo, hi = metrics.joint_bootstrap(owner, other, n, fn, 200, 1)
        per = {str(i): np.flatnonzero(owner == i) for i in range(n)}
        _, lo2, hi2 = metrics.bootstrap_ci(per, lambda r: metrics.eer(sc[r], lab[r])[0], 200, 1)
        self.assertGreater(hi - lo, hi2 - lo2)

    def test_bootstrap_constant_and_paired(self):
        per = {str(i): np.array([i]) for i in range(10)}
        vals = np.full(10, 0.3)
        p, lo, hi = metrics.bootstrap_ci(per, lambda r: float(vals[r].mean()), 100, 1)
        self.assertAlmostEqual(p, 0.3)
        self.assertAlmostEqual(lo, 0.3)
        self.assertAlmostEqual(hi, 0.3)
        a = {str(i): 1.0 + i for i in range(10)}
        b = {str(i): float(i) for i in range(10)}
        self.assertEqual(metrics.paired_bootstrap_diff(a, b, 50), (1.0, 1.0, 1.0))


def fake_speaker(spk: str, chapters: dict[str, int], seconds: float = 6.0,
                 projects: dict[str, str] | None = None) -> list[roles.Utt]:
    out = []
    for ch, n in chapters.items():
        for i in range(n):
            proj = projects[ch] if projects else ""
            out.append(roles.Utt(f"{spk}-{ch}-{i:04d}", spk, ch, int(seconds * 16000), proj))
    return out


class RolesTest(unittest.TestCase):
    def check_partition(self, r: roles.DevRoles, utts):
        ids = set(u.id for u in utts)
        parts = [set(r.E), set(r.A), set(r.R), set(r.T)]
        for i in range(4):
            self.assertTrue(parts[i] <= ids)
            for j in range(i + 1, 4):
                self.assertFalse(parts[i] & parts[j])
        self.assertTrue(roles.E_MIN <= len(r.E) <= roles.E_TARGET)
        self.assertEqual(len(r.R), roles.R_SIZE)
        self.assertGreaterEqual(len(r.T), 2)
        self.assertGreaterEqual(sum(16000 * 6 for _ in r.A), roles.A_SECONDS * 16000)
        self.assertEqual(set(r.H), set(r.R) | set(r.T))

    def test_chapter_disjoint_when_possible(self):
        utts = fake_speaker("84", {"121123": 29, "121550": 36})
        r = roles.assign_dev_roles(utts, 1)
        self.check_partition(r, utts)
        self.assertFalse(r.same_chapter)
        ch = lambda ids: {i.split("-")[1] for i in ids}
        self.assertFalse(ch(r.E) & ch(r.H))
        self.assertFalse(ch(r.A) & ch(r.H))  # the audio attacker sits on the profile side
        self.assertEqual(r.separation, "chapter")
        self.assertEqual(r, roles.assign_dev_roles(list(reversed(utts)), 1))  # order-free, deterministic

    def test_smallest_feasible_enrollment_chapter_set(self):
        utts = fake_speaker("1993", {"1": 31, "2": 11, "3": 9, "4": 7})
        r = roles.assign_dev_roles(utts, 1)
        self.assertFalse(r.same_chapter)
        # The profile side needs 20 utterances for E plus 12 s (two 6 s
        # utterances) for A. {2,3} = 20 leaves no room for A; the smallest
        # feasible set is {2,3,4} = 27 (smaller than {1} = 31).
        self.assertEqual({i.split("-")[1] for i in r.E + r.A}, {"2", "3", "4"})

    def test_project_separation_preferred(self):
        # chapters 1 and 2 share project P; chapter 3 is project Q
        utts = fake_speaker("7", {"1": 12, "2": 12, "3": 30}, projects={"1": "P", "2": "P", "3": "Q"})
        r = roles.assign_dev_roles(utts, 1)
        self.assertEqual(r.separation, "project")
        proj = {"1": "P", "2": "P", "3": "Q"}
        pe = {proj[i.split("-")[1]] for i in r.E + r.A}
        ph = {proj[i.split("-")[1]] for i in r.H}
        self.assertFalse(pe & ph)

    def test_chapter_fallback_when_one_project(self):
        utts = fake_speaker("8", {"1": 25, "2": 30}, projects={"1": "P", "2": "P"})
        r = roles.assign_dev_roles(utts, 1)
        self.assertEqual(r.separation, "chapter")

    def test_parse_chapters_txt(self):
        txt = "; comment\n1      | 110  | 19.77 | train-other-500  | 53   | 1023  | In Chancery | Bleak House\n"
        self.assertEqual(roles.parse_chapters_txt(txt), {"1": "53"})

    def test_same_chapter_fallback(self):
        utts = fake_speaker("422", {"1": 36})
        r = roles.assign_dev_roles(utts, 1)
        self.check_partition(r, utts)
        self.assertTrue(r.same_chapter)
        utts = fake_speaker("2086", {"1": 5, "2": 50})
        self.assertTrue(roles.assign_dev_roles(utts, 1).same_chapter)
        r = roles.assign_dev_roles(utts, 1)
        self.check_partition(r, utts)

    def test_short_speaker_gets_smaller_pool(self):
        utts = fake_speaker("6599", {"1": 24})
        r = roles.assign_dev_roles(utts, 1)
        self.assertTrue(roles.E_MIN <= len(r.E) < roles.E_TARGET)
        self.assertGreaterEqual(len(r.R) + len(r.T), roles.V_MIN)

    def test_too_few_raises(self):
        with self.assertRaises(ValueError):
            roles.assign_dev_roles(fake_speaker("9", {"1": 20}), 1)

    def test_train_selection_and_crops(self):
        ids = [f"100-5-{i:04d}" for i in range(70)]
        a = roles.select_train_utts(ids, "100", 3)
        self.assertEqual(len(a), 40)
        self.assertEqual(a, roles.select_train_utts(list(reversed(ids)), "100", 3))
        self.assertEqual(len(roles.select_train_utts(ids[:10], "100", 3)), 10)
        for n in (16000, 32000, 32001, 200000):
            o = roles.crop_offset("100-5-0001", n, 32000, 9)
            self.assertTrue(0 <= o <= max(0, n - 32000))


class ProtectionTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.X, cls.y, cls.means = synth_speakers(60, 12, 0)
        cls.Xd, cls.yd, _ = synth_speakers(8, 12, 1)

    def fitted(self, name):
        return build(name, 5).fit(self.X, self.y, 5)

    def test_grid_shapes_bytes_scores(self):
        import re

        for name in GRID:
            # synthetic data: D = 24 and 60 speakers, so shrink dimensions and anchors
            name = re.sub(r"(pca|lda|anchor)\d+", lambda m: m.group(1) + "16", name)
            with self.subTest(name=name):
                if name == "linfn":
                    p = transforms.LinearFunction(cohort_speakers=30).fit(self.X, self.y, 5)
                else:
                    p = self.fitted(name)
                E = [self.Xd[self.yd == s][:5] for s in np.unique(self.yd)]
                T = p.protect_from_utterances(E, np.random.default_rng(0))
                self.assertEqual(len(T), 8)
                self.assertEqual(len(p.to_bytes(T[0])), math.ceil(p.stored_bits() / 8))
                S = p.score(T, p.probe(self.Xd))
                self.assertEqual(S.shape, (8, len(self.Xd)))
                self.assertTrue(np.isfinite(S).all())
                F = p.features(T)
                self.assertEqual(F.ndim, 2)
                # utility on well-separated synthetic speakers: own utterances score higher
                own = np.array([S[i, self.yd == s].mean() for i, s in enumerate(np.unique(self.yd))])
                other = np.array([S[i, self.yd != s].mean() for i, s in enumerate(np.unique(self.yd))])
                self.assertTrue(np.all(own > other), name)

    def test_unknown_names_rejected(self):
        for bad in ("foo", "raw+zz", "linfn+q1", "raw+q1+q2"):
            with self.assertRaises(ValueError):
                build(bad, 0)

    def test_float_templates_update_exactly(self):
        # Production contract: the stored template of a float32 protection is the
        # projected running mean of the per-utterance normalised embeddings, so
        # streaming updates from (template, count) equal batch enrollment.
        for name in ("raw", "center", "pca16", "lda16", "anchor16", "keyrot"):
            p = self.fitted(name)
            xs = self.Xd[:7]
            batch = p.protect_from_utterances([xs])
            T = p.protect_from_utterances([xs[:3]])
            for n in range(3, 7):
                T = p.update(T, np.array([n]), xs[n : n + 1])
            np.testing.assert_allclose(T.astype(float), batch.astype(float), atol=1e-5)
        with self.assertRaises(NotImplementedError):
            self.fitted("center+sh32").update(np.zeros((1, 32)), np.array([1]), xs[:1])

    def test_keyrot_inverts_with_key_only(self):
        p = self.fitted("keyrot")
        E = [self.Xd[i : i + 1] for i in range(5)]
        C = l2n(self.Xd[:5])
        T = p.protect_from_utterances(E)
        np.testing.assert_allclose(p.analytic_inverse(T), C, atol=1e-5)
        wrong = transforms.KeyedRotation(p.base.key + 1).fit(self.X, self.y, None)
        self.assertLess(np.abs(np.sum(wrong.inverse(p.features(T)) * C, 1)).mean(), 0.6)
        # Scores are exactly the raw cosine: the key buys nothing for utility.
        raw = self.fitted("raw")
        np.testing.assert_allclose(p.score(T, p.probe(self.Xd)),
                                   raw.score(raw.protect_from_utterances(E), raw.probe(self.Xd)), atol=1e-3)

    def test_quantiser_error_falls_with_bits(self):
        errs = []
        E = [self.Xd[i : i + 1] for i in range(20)]
        for b in (1, 2, 4):
            p = self.fitted(f"center+q{b}")
            V = p.base.forward(self.Xd[:20])
            errs.append(1 - np.mean(np.sum(p.encoder.decode(p.protect_from_utterances(E)) * V, 1)))
        self.assertTrue(errs[0] > errs[1] > errs[2] >= 0)

    def test_quant_consistent_respects_codes(self):
        p = self.fitted("center+q2")
        E = [self.Xd[i : i + 1] for i in range(10)]
        T = p.protect_from_utterances(E)
        rng = np.random.default_rng(1)
        x0 = p.base.forward(self.Xd[:10]) + 0.15 * rng.standard_normal((10, D))  # a rough estimate
        x, ok = attacks.quant_consistent(p.encoder, T, x0, return_feasible=True)
        self.assertTrue(ok.all())
        np.testing.assert_array_equal(p.encoder.encode(x), T)
        # r3 #4: boundary-feasible cell, start at the opposite direction
        enc3 = transforms.Quantizer(3)
        enc3.p, enc3.scale = 3, np.array([2 / 3, 8 / 9, 8 / 9])
        v = np.array([[1 / 3, 2 / 3, 2 / 3]])
        code3 = enc3.encode(v)
        x, ok = attacks.quant_consistent(enc3, code3, -v, return_feasible=True)
        self.assertTrue(ok.all())
        np.testing.assert_array_equal(enc3.encode(x), code3)
        # a cell that does not meet the sphere is reported infeasible
        enc4 = transforms.Quantizer(2)
        enc4.p, enc4.scale = 2, np.ones(2)
        _, ok = attacks.quant_consistent(enc4, np.array([[2, 2]], dtype=np.uint8), np.array([[1.0, 0.0]]),
                                         return_feasible=True)
        self.assertFalse(ok.any())
        # r2 case: unit scales, 2-bit code [2, 3], start direction [1, -1]
        enc = transforms.Quantizer(2)
        enc.p, enc.scale = 2, np.ones(2)
        code = np.array([[2, 3]], dtype=np.uint8)
        x, ok = attacks.quant_consistent(enc, code, np.array([[1.0, -1.0]]), return_feasible=True)
        self.assertTrue(ok.all())
        np.testing.assert_array_equal(enc.encode(x), code)

    def test_simhash_bits_and_decode(self):
        p = self.fitted("center+sh64")
        T = p.protect_from_utterances([self.Xd[i : i + 1] for i in range(3)])
        self.assertEqual(T.shape, (3, 64))
        self.assertTrue(set(np.unique(T)) <= {0, 1})
        self.assertTrue(set(np.unique(p.features(T))) <= {-1.0, 1.0})
        np.testing.assert_allclose(np.linalg.norm(p.encoder.decode(T), axis=1), 1.0)
        self.assertEqual(len(p.to_bytes(T[0])), 8)

    def test_sign_consistent_beats_signed_sum(self):
        rng = np.random.default_rng(0)
        H = rng.standard_normal((16, 128))
        X = l2n(rng.standard_normal((20, 16)))
        B = (X @ H > 0).astype(np.uint8)
        dec = l2n((2.0 * B - 1) @ H.T)
        mm, ok = attacks.sign_consistent(H, B, return_feasible=True)
        self.assertTrue(ok.all())
        self.assertEqual(attacks.sign_violations(H, B, mm), 0.0)
        # r2 case: 32 dims, 256 bits, where a finite penalty alone left violations
        H2 = rng.standard_normal((32, 256))
        X2 = l2n(rng.standard_normal((20, 32)))
        B2 = (X2 @ H2 > 0).astype(np.uint8)
        for x0 in (None, l2n((2.0 * B2 - 1) @ H2.T)):
            _, ok2 = attacks.sign_consistent(H2, B2, x0, return_feasible=True)
            self.assertTrue(ok2.all())
        self.assertGreater(attacks.mean_cos(mm, X), attacks.mean_cos(dec, X))
        pj = attacks.sign_consistent(H, B, dec)
        self.assertEqual(attacks.sign_violations(H, B, pj), 0.0)

    def test_noise_needs_rng_reproducible_and_undone_by_leaked_seed(self):
        p = self.fitted("center+noise0.5")
        E = [self.Xd[i : i + 1] for i in range(4)]
        with self.assertRaises(ValueError):
            p.protect_from_utterances(E)
        a = p.protect_from_utterances(E, np.random.default_rng(3))
        np.testing.assert_array_equal(a, p.protect_from_utterances(E, np.random.default_rng(3)))
        self.assertFalse(np.allclose(a, p.protect_from_utterances(E, np.random.default_rng(4))))
        np.testing.assert_allclose(np.linalg.norm(a, axis=1), 1.0, atol=1e-6)
        N = p.encoder.noise(a.shape, np.random.default_rng(3))
        v = transforms.Noise.undo(a.astype(np.float64), N)
        np.testing.assert_allclose(v, p.base.forward(self.Xd[:4]), atol=1e-5)

    def test_linfn_separates_owner_from_cohort_and_kkt_inverts(self):
        p = transforms.LinearFunction(cohort_speakers=30, steps=200).fit(self.X, self.y, 1)
        own = self.Xd[self.yd == self.yd[0]]
        T = p.protect_from_utterances([own[:6]])
        s_own = p.score(T, p.probe(own[6:]))
        s_coh = p.score(T, p.probe(p.N + p.mu))
        s = np.concatenate([s_own[0], s_coh[0]])
        lab = np.r_[np.ones(s_own.shape[1]), np.zeros(s_coh.shape[1])]
        self.assertLess(metrics.eer(s, lab)[0], 0.1)
        self.assertEqual(T.shape, (1, D + 1))
        # The KKT conditions reveal a weighted mean of the enrollment embeddings.
        c = l2n(own[:6].mean(0))
        self.assertGreater(float(p.analytic_inverse(T)[0] @ c), 0.98)


class AttackTest(unittest.TestCase):
    def test_ridge_recovers_linear_map(self):
        rng = np.random.default_rng(0)
        C = l2n(rng.standard_normal((800, 10)))
        M = rng.standard_normal((10, 6))
        F = C @ M
        r = attacks.Ridge().fit(F[:600], C[:600], F[600:700], C[600:700])
        # 6 of 10 dims are observed: recovery is partial but far above chance
        self.assertGreater(attacks.mean_cos(r.invert(F[700:]), C[700:]), 0.6)
        F_full = C @ rng.standard_normal((10, 12))
        r = attacks.Ridge().fit(F_full[:600], C[:600], F_full[600:700], C[600:700])
        self.assertGreater(attacks.mean_cos(r.invert(F_full[700:]), C[700:]), 0.99)

    def test_mlp_runs_and_learns(self):
        rng = np.random.default_rng(1)
        C = l2n(rng.standard_normal((600, 8)))
        F = np.tanh(C @ rng.standard_normal((8, 12)))
        m = attacks.MLP(0, hidden=64, epochs=40, patience=5).fit(F[:400], C[:400], F[400:500], C[400:500])
        self.assertGreater(attacks.mean_cos(m.invert(F[500:]), C[500:]), 0.8)

    def test_nearest_public_and_pseudo_profiles(self):
        X, y, _ = synth_speakers(30, 10, 2)
        pp = attacks.sample_pseudo_profiles(X, y, 4, (3, 5), 0)
        self.assertEqual(len(pp.C), 120)
        for m, s in zip(pp.members, pp.speaker):
            self.assertTrue(np.all(y[m] == s))
        tr, va = attacks.split_speakers(pp.speaker, 0.2, 0)
        self.assertFalse(set(tr) & set(va))
        self.assertEqual(len(tr) + len(va), 30)
        p = build("raw", 0).fit(X, y, 0)
        spk, G = np.unique(y), np.stack([l2n(X[y == s].mean(0)) for s in np.unique(y)])
        knn = attacks.NearestPublic(p, G, k=1)
        T = p.protect_from_utterances([G[i : i + 1] for i in range(3)])
        np.testing.assert_allclose(knn.invert_templates(T), G[:3], atol=1e-6)


class CacheTest(unittest.TestCase):
    rows = [embcache.Row("1-2-0001", "1", "2", "F", -1, -1, 32000),
            embcache.Row("1-2-0001", "1", "2", "F", 100, 32000, 64000)]

    def emb(self):
        return l2n(np.random.default_rng(0).standard_normal((2, 5))).astype(np.float32)

    def test_round_trip_generation_and_validation(self):
        emb = self.emb()
        meta = {"embedder": "x", "split": "dev", "limit_speakers": 0}
        with tempfile.TemporaryDirectory() as d:
            target = Path(d) / "x" / "dev"
            g1 = embcache.write(target, meta, self.rows, emb)
            c = embcache.read(target)
            self.assertEqual(c.rows, self.rows)
            np.testing.assert_array_equal(c.emb, emb)
            self.assertEqual(c.meta["generation"], g1)
            self.assertEqual(len(c.select(full=True)[0]), 1)
            embcache.validate(c, "x", "dev", {("1-2-0001", True), ("1-2-0001", False)})
            g2 = embcache.write(target, meta, self.rows, -emb)
            self.assertNotEqual(g1, g2)
            self.assertEqual(embcache.current_generation(target), g2)
            # generations are immutable and kept; a pinned reader still gets g1
            np.testing.assert_array_equal(embcache.read(target, g1).emb, emb)
            self.assertEqual(sorted(p.name for p in target.iterdir()), sorted(["CURRENT", f"gen-{g1}", f"gen-{g2}"]))
            self.assertEqual(embcache.write(target, meta, self.rows, emb), g1)  # same content, same id
            for bad_emb in (emb * 2, emb.astype(np.float64)):
                with self.assertRaises(ValueError):
                    embcache.write(target, {}, self.rows, bad_emb)
            self.assertEqual(embcache.current_generation(target), g1)  # failed writes publish nothing

    def test_read_detects_tampering(self):
        with tempfile.TemporaryDirectory() as d:
            a = Path(d) / "a"
            g = embcache.write(a, {"embedder": "x", "split": "dev"}, self.rows, self.emb())
            np.save(a / f"gen-{g}" / "emb.npy", -self.emb())  # same shape, other bytes
            with self.assertRaises(ValueError):
                embcache.read(a)

    def test_smoke_guard(self):
        root = Path("/tmp/w4root/emb")
        for bad in (root, root / "x" / "dev", root.parent, Path("/tmp")):
            self.assertTrue(embcache.is_inside_or_contains(bad, root), bad)
        self.assertFalse(embcache.is_inside_or_contains(Path("/tmp/w4smoke/emb"), root))

    def test_validate_rejects_partial_wrong_or_incomplete(self):
        with tempfile.TemporaryDirectory() as d:
            t = Path(d) / "c"
            ids = {("1-2-0001", True), ("1-2-0001", False)}
            embcache.write(t, {"embedder": "x", "split": "dev", "limit_speakers": 2}, self.rows, self.emb())
            with self.assertRaises(ValueError):
                embcache.validate(embcache.read(t), "x", "dev", ids)
            embcache.write(t, {"embedder": "x", "split": "dev", "limit_speakers": 0}, self.rows, self.emb())
            c = embcache.read(t)
            for args in (("y", "dev", ids), ("x", "train", ids), ("x", "dev", ids | {("1-2-0002", True)})):
                with self.assertRaises(ValueError):
                    embcache.validate(c, *args)


if __name__ == "__main__":
    unittest.main()
