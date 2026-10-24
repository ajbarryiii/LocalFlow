import unittest

import numpy as np
import torch

from lfspk.probe import backend as B
from lfspk.probe import models
from lfspk.probe import pooling
from lfspk.probe import report as R


class TestPooling(unittest.TestCase):
    def test_masked_stats_ignore_padding(self):
        g = torch.Generator().manual_seed(0)
        x = torch.randn(3, 10, 4, generator=g)
        lengths = torch.tensor([10, 4, 1])
        y = pooling.mean_std(x, lengths)
        self.assertEqual(tuple(y.shape), (3, 8))
        for b, n in enumerate(lengths.tolist()):
            ref = torch.cat([x[b, :n].double().mean(0), x[b, :n].double().std(0, unbiased=False)])
            torch.testing.assert_close(y[b], ref)
        x2 = x.clone()
        x2[1, 4:] = 1e6
        torch.testing.assert_close(pooling.mean_std(x2, lengths), y)

    def test_rejects_bad_lengths(self):
        with self.assertRaises(ValueError):
            pooling.mean_std(torch.zeros(1, 3, 2), torch.tensor([0]))
        with self.assertRaises(ValueError):
            pooling.mean_std(torch.zeros(1, 3, 2), torch.tensor([4]))


class TestUnpack(unittest.TestCase):
    def test_round_trip(self):
        rng = np.random.default_rng(0)
        codes = rng.integers(-1, 2, size=(5, 11)).astype(np.int8)
        packed = np.zeros((5, 3), np.uint8)
        for o in range(5):
            for j in range(11):
                f = {0: 0, 1: 1, -1: 2}[int(codes[o, j])]
                packed[o, j // 4] |= f << (2 * (j % 4))
        out = models.unpack_codes(torch.from_numpy(packed), 11)
        np.testing.assert_array_equal(out.numpy(), codes)

    def test_rejects_invalid(self):
        with self.assertRaises(ValueError):
            models.unpack_codes(torch.tensor([[3]], dtype=torch.uint8), 4)
        with self.assertRaises(ValueError):  # nonzero tail padding
            models.unpack_codes(torch.tensor([[1 << 6]], dtype=torch.uint8), 3)


def clusters(n_spk, per, dim, rng, noise_dims=0, spread=1.0):
    centres = rng.normal(size=(n_spk, dim)) * spread
    y = np.repeat(np.arange(n_spk), per)
    x = centres[y] + rng.normal(size=(y.size, dim))
    if noise_dims:
        # high-variance nuisance dimensions carrying no identity
        x = np.c_[x, 10 * rng.normal(size=(y.size, noise_dims))]
    return x, y


class TestBackend(unittest.TestCase):
    def test_lda_ignores_nuisance_and_generalises_to_new_speakers(self):
        rng = np.random.default_rng(1)
        xtr, ytr = clusters(60, 10, 8, rng, noise_dims=24, spread=2.0)
        be = B.Backend.fit(xtr, ytr, dim=8)
        self.assertEqual(be.proj.shape, (32, 8))
        # new speakers drawn the same way (generalisation, not memorisation)
        rng2 = np.random.default_rng(2)
        xte, yte = clusters(20, 6, 8, rng2, noise_dims=24, spread=2.0)
        e = be.transform(xte)
        np.testing.assert_allclose(np.linalg.norm(e, axis=1), 1.0)
        s = e @ e.T
        same = yte[:, None] == yte[None, :]
        off = ~np.eye(len(yte), dtype=bool)
        from lfspk.probe.metrics import eer
        lda_eer = eer(s[off], same[off])
        raw = B.l2norm(xte - xtr.mean(0))
        raw_eer = eer((raw @ raw.T)[off], same[off])
        self.assertLess(lda_eer, 0.1)
        self.assertLess(lda_eer, raw_eer)

    def test_dim_capped_by_classes(self):
        rng = np.random.default_rng(3)
        x, y = clusters(5, 10, 20, rng)
        self.assertEqual(B.Backend.fit(x, y, dim=200).proj.shape[1], 4)

    def test_npz_round_trip(self):
        rng = np.random.default_rng(4)
        x, y = clusters(6, 5, 7, rng)
        be = B.Backend.fit(x, y, dim=3)
        be2 = B.Backend.from_npz(be.to_npz())
        np.testing.assert_allclose(be.transform(x), be2.transform(x))

    def test_enrollment_model(self):
        e = B.enrollment_model(np.array([[2.0, 0.0], [0.0, 1.0]]))
        np.testing.assert_allclose(e, [np.sqrt(0.5), np.sqrt(0.5)])


class TestTrialSet(unittest.TestCase):
    def meta(self):
        return {
            "speakers": np.array(["1", "2", "3", "4"]),
            "sex": np.array(["F", "F", "M", "M"]),
            "session": np.array(["cross_project", "same_chapter", "cross_chapter", "cross_project"]),
            "half_S": np.array(["4"]),
            "half_E": np.array(["1", "2", "3"]),
            "model_speaker": np.array(["1", "1", "2", "3", "4"]),
            "test_speaker": np.array(["1", "2", "3", "4"]),
        }

    def test_subsets(self):
        m = self.meta()
        s = np.arange(20, dtype=float).reshape(5, 4)
        t = R.trial_set(m, "all")
        self.assertEqual((t.index.size, int(t.labels.sum()), t.n_groups), (20, 5, 4))
        np.testing.assert_array_equal(t.g_enroll, np.repeat([0, 0, 1, 2, 3], 4))
        np.testing.assert_array_equal(t.g_test, np.tile([0, 1, 2, 3], 5))
        np.testing.assert_array_equal(t.strata, [0, 2, 1, 0])
        t = R.trial_set(m, "same_sex")
        # F models (1,1,2) keep tests 1,2; M models (3,4) keep tests 3,4
        self.assertEqual(t.index.size, 10)
        self.assertEqual(int(t.labels.sum()), 5)
        t = R.trial_set(m, "cross_chapter")
        self.assertEqual(t.index.size, 16)  # model of speaker 2 removed
        t = R.trial_set(m, "cross_project")
        self.assertEqual(t.index.size, 12)  # models of speakers 1, 1, 4
        np.testing.assert_array_equal(s.ravel()[t.index][:4], [0, 1, 2, 3])

    def test_halves_restrict_both_roles(self):
        m = self.meta()
        t = R.trial_set(m, "all", "E")
        self.assertEqual(t.n_groups, 3)
        self.assertEqual(t.index.size, 4 * 3)  # models 1,1,2,3 x tests 1,2,3
        self.assertTrue((t.g_enroll >= 0).all() and (t.g_test >= 0).all())
        t = R.trial_set(m, "all", "S")
        self.assertEqual(t.index.size, 1)

    def test_h3_verdict(self):
        self.assertEqual(R.h3_verdict({"value": 0.0, "lo": -0.005, "hi": 0.006})["verdict"], "equivalent within margin")
        self.assertEqual(R.h3_verdict({"value": 0.02, "lo": 0.012, "hi": 0.03})["verdict"], "different")
        self.assertEqual(R.h3_verdict({"value": 0.0, "lo": -0.02, "hi": 0.02})["verdict"], "inconclusive")

    def test_bad_metadata(self):
        m = self.meta()
        m["model_speaker"] = np.zeros((2, 2))
        with self.assertRaises(ValueError):
            R.trial_set(m, "all")


if __name__ == "__main__":
    unittest.main()
