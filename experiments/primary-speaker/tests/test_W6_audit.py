"""W6 augmentation audit statistics and stop rules (DESIGN 2.4), on synthetic signals."""

from __future__ import annotations

import unittest

import numpy as np

from lfspk.extract.frontend import analytic_mel_power
from lfspk.personal import audit as A


def _noise(n, rng, tilt=0.0):
    x = rng.standard_normal(n)
    if tilt:
        x = np.convolve(x, [1.0, tilt], mode="same")  # a first-order colouring (channel difference)
    return (0.05 * x).astype(np.float32)


class TestChannel(unittest.TestCase):
    def setUp(self):
        self.mel = analytic_mel_power()
        self.rng = np.random.default_rng(0)
        self.n = 16000 * 3
        self.act = np.ones(self.n // 160, bool)

    def test_gain_invariant(self):
        x = _noise(self.n, self.rng)
        self.assertLess(A.channel_distance(x, self.act, 0.1 * x, self.act, self.mel), 1e-6)

    def test_detects_colouring(self):
        x, y = _noise(self.n, self.rng), _noise(self.n, np.random.default_rng(1))
        same = A.channel_distance(x, self.act, y, self.act, self.mel)
        coloured = A.channel_distance(x, self.act, _noise(self.n, np.random.default_rng(1), tilt=0.9), self.act, self.mel)
        self.assertGreater(coloured, same + 1.0)

    def test_s3_kept_share_undefined_at_zero_baseline(self):
        # sol code1-r2 m1: c0 = 0 with 50 recovered frames is undefined, not 50.0
        self.assertIsNone(A.s3_kept_share({"s3_baseline_frames": 0, "interf_active_frames": 50}))
        self.assertEqual(A.s3_kept_share({"s3_baseline_frames": 300, "interf_active_frames": 270}), 0.9)
        self.assertEqual(A.summary([None, 0.9, 1.0])["n"], 2)

    def test_overlap(self):
        self.assertEqual(A.overlap_share(np.array([1, 1, 0, 0], bool), np.array([0, 1, 1, 0], bool)), 0.5)


def _tables(channel_med=1.0, mixed_p95=2.0, ov=0.4, donor_ov=0.5):
    t = {}
    for f in ("S1", "S2", "S3", "S4"):
        t[f] = {"transplant": {"channel": {"median": channel_med}, "overlap": {"median": ov}},
                "donor": {"overlap": {"median": donor_ov}}, "mixed": {"channel": {"p95": mixed_p95}}}
    return t


class TestVerdict(unittest.TestCase):
    def test_proceed(self):
        self.assertTrue(A.verdict(_tables(), 0.01)["proceed"])

    def test_sir_bug(self):
        v = A.verdict(_tables(), 0.2)
        self.assertEqual((v["proceed"], v["kind"]), (False, "bug"))

    def test_channel_stop(self):
        v = A.verdict(_tables(channel_med=3.0), 0.0)
        self.assertEqual((v["proceed"], v["kind"]), (False, "method"))

    def test_overlap_stop_s3_exempt(self):
        t = _tables()
        t["S3"]["transplant"]["overlap"]["median"] = 0.0
        self.assertTrue(A.verdict(t, 0.0)["proceed"])
        t["S4"]["transplant"]["overlap"]["median"] = 0.2
        self.assertFalse(A.verdict(t, 0.0)["proceed"])


if __name__ == "__main__":
    unittest.main()


class TestDryrun(unittest.TestCase):
    def test_counts_and_exhaustion(self):
        from tests.test_W6_stream import fake_bank, make_dictation

        rng = np.random.default_rng(4)
        dicts = [make_dictation(rng) for _ in range(10)]
        res = A._dryrun_subject("2775", dicts=dicts, bank=fake_bank(empty_first=True, n=6), n=200)
        self.assertEqual(res["examples"], 200)
        per = res["rejections_by_dictation"]
        self.assertTrue(per and all(set(v) == {"draws", "total", "max"} for v in per.values()))
        self.assertEqual(sum(v["draws"] for v in per.values()),
                         sum(res["rejections"][f]["draws"] for f in res["rejections"]))
        with self.assertRaises(RuntimeError):  # every donor empty -> exhaustion fails loudly
            A._dryrun_subject("2775", dicts=dicts, bank=fake_bank(empty_first=True, n=2), n=200)
