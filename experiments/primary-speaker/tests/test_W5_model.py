"""W5 mask network and losses (DESIGN sections 5-6)."""

from __future__ import annotations

import unittest

import numpy as np
import torch

from lfspk.extract import losses, model
from lfspk.extract.api import LOG_G_MIN


class TestMaskNet(unittest.TestCase):
    def setUp(self):
        torch.manual_seed(0)
        self.cfg = model.config_for("M")
        self.net = model.MaskNet(self.cfg).eval()

    def test_shapes_and_range(self):
        x = torch.randn(3, 128, 201)
        lm, u = self.net(x, torch.randn(3, 192), torch.tensor([201, 150, 7]))
        self.assertEqual(lm.shape, (3, 128, 201))
        self.assertEqual(u.shape, (3, 201))
        self.assertGreaterEqual(float(lm.min()), LOG_G_MIN - 1e-6)
        self.assertLessEqual(float(lm.max()), 0.0)
        self.assertTrue(torch.all(lm[1, :, 150:] == 0))  # frames past the valid count: no mask

    def test_untrained_net_passes_features_through(self):
        lm, _ = self.net(torch.randn(1, 128, 300), torch.randn(1, 192))
        self.assertGreater(float(lm.min()), -0.05)  # MASK_BIAS_INIT: about -0.2 dB

    def test_odd_lengths(self):
        for t in (1, 2, 3, 99, 100):
            lm, u = self.net(torch.randn(1, 128, t), torch.randn(1, 192))
            self.assertEqual(lm.shape[-1], t)
            self.assertEqual(u.shape[-1], t)

    def test_padding_does_not_leak_into_valid_frames(self):
        # implI2-r1 #4: non-zero head weights, both heads, odd and even valid lengths
        net = model.MaskNet(self.cfg).eval()
        with torch.no_grad():
            torch.nn.init.normal_(net.mask_head.weight, std=0.2)
            torch.nn.init.normal_(net.aux_head.weight, std=0.2)
            for f in net.films:
                torch.nn.init.normal_(f.lin.weight, std=0.05)
        e = torch.randn(1, 192)
        torch.set_grad_enabled(False)
        self.addCleanup(torch.set_grad_enabled, True)
        for valid in (120, 121, 7):
            x = torch.randn(1, 128, valid)
            a_lm, a_u = net(x, e, torch.tensor([valid]))
            self.assertGreater(float(a_lm.std()), 1e-3)  # the mask is not constant
            xp = torch.cat([x, 50 * torch.randn(1, 128, 81)], dim=-1)
            b_lm, b_u = net(xp, e, torch.tensor([valid]))
            torch.testing.assert_close(a_lm, b_lm[:, :, :valid], atol=1e-5, rtol=0)
            torch.testing.assert_close(a_u, b_u[:, :valid], atol=1e-5, rtol=0)

    def test_profile_conditions_output_after_training_steps(self):
        # FiLM starts at the identity and the mask head at zero weights; a few steps make the profile matter
        net = model.MaskNet(self.cfg)
        opt = torch.optim.Adam(net.parameters(), lr=1e-2)
        x, e = torch.randn(2, 128, 64), torch.randn(2, 192)
        for _ in range(3):
            opt.zero_grad()
            lm, u = net(x, e)
            ((lm - LOG_G_MIN).square().mean() + u.square().mean()).backward()
            opt.step()
        with torch.no_grad():
            a, _ = net(x[:1], e[:1])
            b, _ = net(x[:1], -e[:1])
        self.assertGreater(float((a - b).abs().max()), 1e-4)

    def test_unconditioned_variant(self):
        net = model.MaskNet(model.config_for("M", "none"))
        lm, _ = net(torch.randn(1, 128, 50), None)
        self.assertEqual(lm.shape, (1, 128, 50))
        with self.assertRaises(ValueError):
            self.net(torch.randn(1, 128, 50), None)

    def test_interleave_order(self):
        z = torch.arange(2 * 3 * 4).float().view(1, 6, 4)  # 2 sub-frames x 3 channels x 4 steps
        out = model._interleave(z, 3, 8)
        self.assertEqual(out[0, 0].tolist(), [0, 12, 1, 13, 2, 14, 3, 15])

    def test_cost(self):
        macs = model.macs_per_second(self.cfg)
        self.assertTrue(25e6 < macs < 35e6, macs)
        self.assertTrue(0.6e6 < model.param_count(self.net) < 0.9e6, model.param_count(self.net))
        s = model.macs_per_second(model.config_for("S"))
        self.assertLess(s, macs)

    def test_cost_matches_flop_counter(self):
        from torch.utils.flop_counter import FlopCounterMode

        t = 1000  # 10 s at 100 fps -> 500 steps
        net = self.net
        x, e = torch.randn(1, 128, t), torch.randn(1, 192)
        with FlopCounterMode(display=False) as fc:
            net(x, e)
        measured_macs = fc.get_total_flops() / 2
        analytic = model.macs_per_second(self.cfg) * 10 + model.per_recording_macs(self.cfg)
        self.assertLess(abs(measured_macs - analytic) / analytic, 0.03, (measured_macs, analytic))


class TestLosses(unittest.TestCase):
    def test_asymmetry(self):
        ideal = torch.zeros(1, 2, 3)
        valid = torch.ones(1, 3)
        over = losses.mask_loss(torch.full((1, 2, 3), -0.5), ideal, valid)  # removes energy y* keeps
        under = losses.mask_loss(torch.full((1, 2, 3), -0.5), torch.full((1, 2, 3), -1.0), valid)  # keeps too much
        self.assertAlmostEqual(float(over), (10 * 0.5) ** 2, places=5)
        self.assertAlmostEqual(float(under), 0.5 ** 2, places=5)

    def test_invalid_frames_ignored(self):
        lm = torch.zeros(1, 2, 4)
        ideal = torch.zeros(1, 2, 4)
        ideal[..., 3] = -5.0
        valid = torch.tensor([[1.0, 1.0, 1.0, 0.0]])
        self.assertEqual(float(losses.mask_loss(lm, ideal, valid)), 0.0)
        u = torch.tensor([[0.0, 0.0, 0.0, 9.0]])
        lab = torch.tensor([[0.0, 1.0, 0.0, 0.0]])
        ref = float(torch.nn.functional.binary_cross_entropy_with_logits(torch.zeros(3), torch.tensor([0.0, 1.0, 0.0])))
        self.assertAlmostEqual(float(losses.aux_loss(u, lab, valid)), ref, places=6)

    def test_total(self):
        lm, ideal = torch.zeros(1, 2, 3), torch.zeros(1, 2, 3)
        total, parts = losses.total_loss(lm, torch.zeros(1, 3), ideal, torch.ones(1, 3), torch.ones(1, 3))
        self.assertAlmostEqual(float(total), 0.1 * float(np.log(2)), places=6)
        self.assertEqual(set(parts), {"mask", "aux"})


if __name__ == "__main__":
    unittest.main()
