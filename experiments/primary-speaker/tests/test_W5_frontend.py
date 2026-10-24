"""W5 front-end contract: api, mel power, apply, safeguard weights, fixtures of DESIGN section 3."""

from __future__ import annotations

import unittest

import numpy as np
import torch

from lfspk.extract import api, frontend
from lfspk.extract.api import LOG_G_MIN, InferenceConfig, MaskOutput

MEL = frontend.analytic_mel_power()  # explicit constants: these tests are about the arithmetic


def X(a):
    return frontend.features_np(a, MEL)


def apply(a, out, cfg):
    return frontend.apply(a, out, cfg, MEL)


def P(a):
    return frontend.mel_power_np(a, MEL)


def noise(n: int, level_db: float, seed: int = 0) -> np.ndarray:
    rng = np.random.default_rng(seed)
    x = rng.standard_normal(n).astype(np.float32)
    return (x / np.sqrt(np.mean(x ** 2)) * 10 ** (level_db / 20)).astype(np.float32)


def zero_mask(n: int) -> MaskOutput:
    t = api.feature_frames(n)
    return MaskOutput(np.zeros((128, t), np.float32), np.zeros(t, np.float32))


class TestApi(unittest.TestCase):
    def test_frames(self):
        self.assertEqual(api.feature_frames(16000), 101)
        self.assertEqual(api.valid_frames(16000), 100)
        self.assertEqual(api.feature_frames(159), 1)

    def test_configs(self):
        self.assertFalse(InferenceConfig("C1").bypass)
        self.assertFalse(InferenceConfig("C1").adaptive)
        self.assertTrue(InferenceConfig("C2").adaptive)
        self.assertEqual(InferenceConfig("C4", 0.3).strength, 0.5)
        with self.assertRaises(ValueError):
            InferenceConfig("C3")  # bypass needs theta_b
        with self.assertRaises(ValueError):
            InferenceConfig("C5")

    def test_check_mask_output(self):
        n = 8000
        api.check_mask_output(zero_mask(n), n)
        t = api.feature_frames(n)
        bad = [MaskOutput(np.zeros((128, t - 1), np.float32), np.zeros(t, np.float32)),
               MaskOutput(np.full((128, t), 0.1, np.float32), np.zeros(t, np.float32)),
               MaskOutput(np.full((128, t), LOG_G_MIN - 0.1, np.float32), np.zeros(t, np.float32)),
               MaskOutput(np.zeros((128, t), np.float32), np.full(t, 1.5, np.float32)),
               MaskOutput(np.zeros((128, t), np.float64), np.zeros(t, np.float32))]
        for b in bad:
            with self.assertRaises((ValueError, TypeError)):
                api.check_mask_output(b, n)
        # float16 storage of a mask at the floor passes (rounding tolerance)
        api.check_mask_output(MaskOutput(np.full((128, t), LOG_G_MIN, np.float16), np.zeros(t, np.float32)), n)


class TestFrontEnd(unittest.TestCase):
    def test_features_match_w3_front_end(self):
        from lfspk.pvad.features import features_np as w3_features

        for n in (16000, 23456, 480):
            a = noise(n, -30, n)
            np.testing.assert_allclose(X(a), w3_features(a), atol=1e-4)

    def test_apply_with_zero_mask_is_x(self):
        a = noise(24000, -30)
        x = X(a)
        for cfg in (InferenceConfig("C1"), InferenceConfig("C2")):
            np.testing.assert_array_equal(apply(a, zero_mask(len(a)), cfg), x)

    def test_constant_mask_cancels_under_normalisation(self):
        # DESIGN section 3 fixture: constant attenuation per bin is undone by per-feature normalisation
        # (outside the guard regime: every masked bin stays >= 1e4 eps)
        from lfspk.pvad.features import LOG_GUARD

        # (the lowest mel bins of pre-emphasised audio are tiny, so only bins whose
        # power stays far from the guard are attenuated)
        a = noise(32000, -10)
        t, m = api.feature_frames(len(a)), api.valid_frames(len(a))
        p = P(a)[:, :m]
        far = p.min(axis=1) > 1e5 * LOG_GUARD
        self.assertGreaterEqual(int(far.sum()), 64)
        c = np.zeros((128, t), np.float32)
        c[far] = np.linspace(np.log(0.1), 0, int(far.sum()), dtype=np.float32)[:, None]
        self.assertGreater(float((p * np.exp(c[:, :m])).min(axis=1)[far].min()), 1e4 * LOG_GUARD)
        out = apply(a, MaskOutput(c, np.zeros(t, np.float32)), InferenceConfig("C1"))
        np.testing.assert_allclose(out, X(a), atol=1e-3)

    def test_quiet_bins_enter_the_guard_regime(self):
        # DESIGN section 3 fixture: near the log guard, log(mP + eps) != log m + log P, so
        # a constant mask no longer cancels; at -150 dBFS almost every bin is in that regime
        loud, quiet = noise(32000, -10, 1), noise(32000, -150, 1)
        s_loud = frontend.guard_regime_share(P(loud), len(loud))
        s_quiet = frontend.guard_regime_share(P(quiet), len(quiet))
        self.assertLess(s_loud, s_quiet)
        self.assertGreater(s_quiet, 0.9)
        t = api.feature_frames(len(quiet))
        c = MaskOutput(np.full((128, t), LOG_G_MIN, np.float32), np.zeros(t, np.float32))
        out = apply(quiet, c, InferenceConfig("C1"))
        self.assertGreater(np.abs(out - X(quiet)).max(), 1e-2)

    def test_time_varying_mask_changes_features(self):
        a = noise(32000, -30)
        t = api.feature_frames(len(a))
        lm = np.zeros((128, t), np.float32)
        lm[:, 50:100] = LOG_G_MIN
        out = apply(a, MaskOutput(lm, np.zeros(t, np.float32)), InferenceConfig("C1"))
        x = X(a)
        self.assertLess(out[:, 60:90].mean(), x[:, 60:90].mean() - 1.0)

    def test_padding_frames_are_zero(self):
        a = noise(16050, -30)
        out = apply(a, zero_mask(len(a)), InferenceConfig("C1"))
        m = api.valid_frames(len(a))
        self.assertTrue((out[:, m:] == 0).all())

    def test_smoothing_and_bypass(self):
        n = 32000
        t, m = api.feature_frames(n), api.valid_frames(n)
        u = np.zeros(t, np.float32)
        u[100] = 1.0
        ubar = frontend.smooth_u(u, n)
        self.assertAlmostEqual(float(ubar[100]), 1 / 51, places=6)
        self.assertAlmostEqual(float(ubar.sum()), 51 / 51, places=5)  # one spike spreads over 51 frames
        self.assertEqual(float(ubar[m:].max(initial=0.0)), 0.0)
        # edges average only the frames the window covers
        u2 = np.ones(t, np.float32)
        np.testing.assert_allclose(frontend.smooth_u(u2, n)[:m], 1.0, atol=1e-6)
        out = MaskOutput(np.zeros((128, t), np.float32), u)
        self.assertIsNone(frontend.weights(u, n, InferenceConfig("C3", 0.05)))
        self.assertTrue(frontend.bypassed(out, n, InferenceConfig("C3", 0.05)))
        self.assertIsNone(frontend.apply(np.zeros(n, np.float32), out, InferenceConfig("C3", 0.05), MEL))
        w3 = frontend.weights(u, n, InferenceConfig("C3", 0.01))
        w4 = frontend.weights(u, n, InferenceConfig("C4", 0.01))
        np.testing.assert_allclose(w4, 0.5 * w3)
        np.testing.assert_array_equal(frontend.weights(u, n, InferenceConfig("C1")), np.ones(t, np.float32))
        np.testing.assert_allclose(frontend.weights(u, n, InferenceConfig("C2")), ubar)

    def test_weights_interpolate_in_log_domain(self):
        a = noise(32000, -30)
        t = api.feature_frames(len(a))
        lm = np.zeros((128, t), np.float32)
        lm[:, 80:160] = -4.0
        u = np.ones(t, np.float32)
        full = apply(a, MaskOutput(lm, u), InferenceConfig("C2"))
        half = apply(a, MaskOutput(lm * 0.5, np.ones(t, np.float32)), InferenceConfig("C2"))
        c4 = apply(a, MaskOutput(lm, u), InferenceConfig("C4", 0.0))
        np.testing.assert_allclose(c4, half, atol=1e-5)
        self.assertFalse(np.allclose(full, half, atol=1e-3))

    def test_ideal_log_mask(self):
        # the raw clipped ratio where P(mix) > 0 (review implI1-r1 #4)
        from lfspk.pvad.features import LOG_GUARD

        p_mix = torch.tensor([[[1.0, 2.0, 0.0, 1e-3, LOG_GUARD, 0.0]]])
        p_tgt = torch.tensor([[[1.0, 1.0, 0.0, 1e-9, 0.0, 1.0]]])
        lm = frontend.ideal_log_mask(p_tgt, p_mix)[0, 0]
        self.assertAlmostEqual(float(lm[0]), 0.0, places=6)
        self.assertAlmostEqual(float(lm[1]), float(np.log(0.5)), places=5)
        self.assertEqual(float(lm[2]), 0.0)  # P(mix) = 0: nothing to remove
        self.assertAlmostEqual(float(lm[3]), LOG_G_MIN, places=5)  # clipped at the floor
        self.assertAlmostEqual(float(lm[4]), LOG_G_MIN, places=5)  # P(y*) = 0 < P(mix) = eps: the floor, not ~0.5
        self.assertEqual(float(lm[5]), 0.0)
        self.assertTrue(torch.isfinite(lm).all())
        self.assertLessEqual(float(frontend.ideal_log_mask(p_mix * 2, p_mix).max()), 0.0)  # P(y*) > P(mix): 1

    @unittest.skipUnless(__import__("lfspk.extract.constants", fromlist=["x"]).available(), "W5 constants not extracted")
    def test_checkpoint_constants(self):
        from pathlib import Path

        from lfspk.extract import constants
        from lfspk.pvad.features import hann_window, mel_filterbank

        w, fb = constants.load()
        self.assertEqual(w.shape, (400,))
        self.assertEqual(fb.shape, (128, 257))
        np.testing.assert_allclose(w, hann_window().numpy(), atol=1e-6)
        np.testing.assert_allclose(fb, mel_filterbank().numpy(), atol=1e-7)
        app = Path("/mnt/hd/wilderness-labs-stt/parakeet-ios/final-memory-20261005/native/frontend.f32bin")
        if app.exists():  # LocalFlow's exported constants (native.py)
            raw = np.fromfile(app, "<f4")
            np.testing.assert_allclose(w, raw[:400], atol=1e-6)
            np.testing.assert_allclose(fb, raw[400:].reshape(128, 257), atol=1e-7)
        with self.assertRaises(ValueError):
            constants.load(sha256="0" * 64)

    def test_default_constants_are_required(self):
        from lfspk.extract import constants

        if constants.available():
            self.assertEqual(frontend.parakeet_mel_power().fb.shape, (1, 128, 257))
        else:
            with self.assertRaises(RuntimeError):
                constants.load()


if __name__ == "__main__":
    unittest.main()
