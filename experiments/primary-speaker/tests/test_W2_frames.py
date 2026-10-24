import unittest

import numpy as np
import torch

from lfspk.api import frame_count
from lfspk.probe import frames as F
from lfspk.probe import framereport as FR
from lfspk.probe import simplemix as SM
from lfspk.probe.backend import Backend
from lfspk.probe.select import activity, rng_for, speaker_of
from lfspk.probe.select import frame_db as S_frame_db

SR = 16000


def tone(seconds, amp, freq=200.0, start=0.0, total=None):
    total = total or seconds
    x = np.zeros(int(total * SR), np.float32)
    n = int(seconds * SR)
    s = int(start * SR)
    x[s:s + n] = amp * np.sin(2 * np.pi * freq * np.arange(n) / SR)
    return x


class TestSimpleMix(unittest.TestCase):
    def test_labels_sir_and_determinism(self):
        target = tone(2.0, 0.3, start=1.0, total=4.0)  # speech in [1, 3) s
        interf = tone(4.0, 0.05, freq=330.0)
        modes = set()
        for k in range(40):
            m1, l1, info = SM.mix(target, interf, rng_for("t", k))
            m2, l2, _ = SM.mix(target, interf, rng_for("t", k))
            np.testing.assert_array_equal(m1, m2)
            np.testing.assert_array_equal(l1, l2)
            modes.add(info.mode)
            self.assertEqual(m1.size, max(info.target_offset + target.size, info.offset + info.length))
            self.assertEqual(l1.size, frame_count(m1.size))
            self.assertLessEqual(np.abs(m1).max(), 0.99 + 1e-6)
            self.assertEqual(info.offset % 160, 0)
            self.assertEqual(info.target_offset % 160, 0)
            # target labels exactly where the (shifted) clean target is active
            t_full = np.zeros(m1.size, np.float32)
            t_full[info.target_offset:info.target_offset + target.size] = target
            np.testing.assert_array_equal(np.isin(l1, (1, 3)), activity(t_full, reference_db=float(
                S_frame_db(target).max())))
            seg = np.zeros(l1.size, bool)
            seg[info.offset // 160:(info.offset + info.length) // 160] = True
            self.assertFalse(np.isin(l1, (2, 3))[~seg].any())
            self.assertTrue(np.isin(l1, (2, 3))[seg].all())  # steady tone: active wherever placed
            if info.mode == "overlap":
                self.assertEqual(m1.size, target.size)
            else:
                ov = max(0, min(info.target_offset + target.size, info.offset + info.length)
                         - max(info.target_offset, info.offset))
                self.assertLessEqual(ov, 0.3 * info.length + 160)
            # realised SIR over active frames
            placed = np.zeros(m1.size)
            placed[info.offset:info.offset + info.length] = interf[info.source_start:info.source_start + info.length]
            sir = (SM.active_rms_db(t_full, np.isin(l1, (1, 3)))
                   - SM.active_rms_db(info.gain * placed, np.isin(l1, (2, 3))))
            self.assertAlmostEqual(sir, info.sir_db, places=6)
            self.assertTrue(-5 <= info.sir_db <= 5)
        self.assertEqual(modes, {"overlap", "turn"})

    def test_turn_mode_yields_interferer_only_frames(self):
        target = tone(5.0, 0.3)
        interf = tone(8.0, 0.3, freq=330.0)
        frac = []
        for k in range(100):
            _, lab, info = SM.mix(target, interf, rng_for("p", k))
            if info.mode == "turn":
                frac.append(np.mean(lab == 2))
        self.assertGreater(len(frac), 25)
        self.assertGreater(np.mean(frac), 0.2)

    def test_encoder_targets_and_upsample(self):
        labels = np.array([0] * 8 + [1] * 4 + [2] * 4 + [3] * 8 + [1] * 3, np.uint8)
        t = SM.encoder_targets(labels, 4)
        np.testing.assert_allclose(t, [0.0, 0.5, 1.0, 3 / 8])
        up = SM.upsample_scores(np.array([0.1, 0.2, 0.3]), 160 * 27)
        self.assertEqual(up.size, 27)
        np.testing.assert_allclose(up[:8], 0.1, rtol=1e-6)
        np.testing.assert_allclose(up[24:], 0.3, rtol=1e-6)
        self.assertEqual(SM.upsample_scores(np.array([0.5]), 160 * 10).size, 10)


class TestHead(unittest.TestCase):
    def test_shapes_and_conditioning(self):
        torch.manual_seed(0)
        h = F.FrameHead(16, 4, True, hidden=8)
        x = torch.randn(2, 7, 16)
        p1, p2 = torch.randn(2, 4), torch.randn(2, 4)
        self.assertEqual(tuple(h(x, p1).shape), (2, 7))
        self.assertFalse(torch.allclose(h(x, p1), h(x, p2)))
        u = F.FrameHead(16, 4, False, hidden=8)
        torch.testing.assert_close(u(x, p1), u(x, None))
        with self.assertRaises(ValueError):
            h(x, None)

    def test_valid_scores_independent_of_padding(self):
        torch.manual_seed(1)
        for cond in (True, False):
            h = F.FrameHead(16, 4, cond, hidden=8)
            x = torch.randn(1, 6, 16)
            p = torch.randn(1, 4)
            ref = h(x, p, torch.tensor([6]))
            padded = torch.cat([x, torch.randn(1, 4, 16) * 5], 1)  # junk padding, as after a cat of micro-batches
            out = h(padded, p, torch.tensor([6]))
            torch.testing.assert_close(out[:, :6], ref)
            # without lengths the last valid frames would see the padding through the conv
            self.assertFalse(torch.allclose(h(padded, p)[:, :6], ref))

    def test_masked_bce_ignores_padding(self):
        lo = torch.tensor([[0.0, 5.0, -100.0]])
        tg = torch.tensor([[0.5, 1.0, 1.0]])
        a = F.masked_bce(lo, tg, torch.tensor([2]))
        b = F.masked_bce(lo[:, :2], tg[:, :2], torch.tensor([2]))
        torch.testing.assert_close(a, b)

    def test_stack_logmel(self):
        feats = torch.arange(2 * 3 * 20, dtype=torch.float32).reshape(2, 3, 20)
        out = F.stack_logmel(feats, torch.tensor([3, 2]), 3)
        self.assertEqual(tuple(out.shape), (2, 3, 24))
        # frame 1 of item 0 = 10 ms frames 8..15, feature-minor within each 10 ms frame
        np.testing.assert_array_equal(out[0, 1].reshape(8, 3).T.numpy(), feats[0, :, 8:16].numpy())
        self.assertTrue(torch.all(out[0, 2, 4 * 3:] == 0))  # frames 20..23 padded
        self.assertTrue(torch.all(out[1, 2] == 0))  # beyond enc_len


def fake_selection(n_spk=12, per=6):
    sel, sex = {}, {}
    for s in range(1, n_spk + 1):
        sel[str(s)] = [f"{s}-{c}-{i:04d}" for c in (10, 20) for i in range(per // 2)]
        sex[str(s)] = "F" if s % 2 else "M"
    return sel, sex


class TestPlans(unittest.TestCase):
    def test_halves(self):
        a, b = F.halves([str(i) for i in range(1, 22)])
        self.assertEqual(len(a), 11)
        self.assertFalse(set(a) & set(b))
        self.assertEqual(F.halves([str(i) for i in reversed(range(1, 22))]), (a, b))

    def test_train_plan(self):
        sel, sex = fake_selection()
        spk = list(sel)
        same = 0
        for i in range(400):
            p = F.train_plan(i, 1, sel, spk, sex)
            F.check_plan(p)
            self.assertEqual(p, F.train_plan(i, 1, sel, spk, sex))
            self.assertNotIn(p.target, p.enroll)
            self.assertTrue(all(u.split("-")[1] != p.target.split("-")[1] for u in p.enroll))
            same += p.same_sex
            self.assertEqual(p.same_sex, sex[speaker_of(p.target)] == sex[speaker_of(p.interferer)])
        self.assertTrue(150 < same < 250)
        self.assertNotEqual(F.train_plan(0, 1, sel, spk, sex), F.train_plan(0, 2, sel, spk, sex))

    def test_check_plan_rejects(self):
        with self.assertRaises(ValueError):
            F.check_plan(F.MixPlan("1-1-0001", "1-2-0001", ("1-1-0002",) * 3, True, "k"))
        with self.assertRaises(ValueError):
            F.check_plan(F.MixPlan("1-1-0001", "2-2-0001", ("1-1-0001", "1-1-0002", "1-1-0003"), True, "k"))

    def test_dev_plans(self):
        plans, sex = [], {}
        for s in range(1, 9):
            sex[str(s)] = "F" if s <= 4 else "M"
            plans.append({"speaker": str(s), "enroll_models": [[f"{s}-1-{k:04d}" for k in range(3)]] * 3,
                          "test": [f"{s}-2-{k:04d}" for k in range(4)]})
        halves = (["1", "2", "5", "6"], ["3", "4", "7", "8"])
        dp = F.dev_plans(plans, sex, halves)
        self.assertEqual(len(dp), 32)
        for j, p in enumerate(dp):
            F.check_plan(p)
            if j % 4 % 2 == 0:
                self.assertTrue(p.same_sex)
            self.assertEqual(p.enroll, tuple(f"{speaker_of(p.target)}-1-{k:04d}" for k in range(3)))
            h = [x for x in halves if speaker_of(p.target) in x][0]
            self.assertIn(speaker_of(p.interferer), h)  # never crosses halves


class TestProfilesAndStats(unittest.TestCase):
    def test_profile_table(self):
        rng = np.random.default_rng(0)
        feats = rng.normal(size=(2, 30, 6))
        y = np.repeat(np.arange(10), 3)
        bes = [Backend.fit(feats[t], y, dim=3) for t in range(2)]
        rows = {f"1-1-{i:04d}": i for i in range(30)}
        tab = F.ProfileTable.build(feats, rows, bes)
        p = tab.profile(["1-1-0000", "1-1-0001"])
        self.assertEqual(p.shape, (2, 3))
        e = bes[1].transform(feats[1][[0, 1]])
        ref = e.mean(0) / np.linalg.norm(e.mean(0))
        np.testing.assert_allclose(p[1], ref, rtol=1e-5)

    def test_frame_stats_from_pooled(self):
        rng = np.random.default_rng(1)
        utts = [rng.normal(loc=rng.normal(), size=(n, 3)) for n in (5, 9, 4)]
        pooled = np.stack([np.r_[u.mean(0), u.std(0)] for u in utts])[None]  # [1, 3, 6]
        mu, sd = F.frame_stats(pooled, [0, 1, 2])
        # equal weight per utterance: mixture of the per-utterance empirical distributions
        ref_mu = np.mean([u.mean(0) for u in utts], 0)
        ref_var = np.mean([(u ** 2).mean(0) for u in utts], 0) - ref_mu ** 2
        np.testing.assert_allclose(mu[0], ref_mu, rtol=1e-5)
        np.testing.assert_allclose(sd[0], np.sqrt(ref_var), rtol=1e-5)


def _est(v, lo=None, hi=None):
    return {"value": v, "lo": v if lo is None else lo, "hi": v if hi is None else hi}


def fake_results(auc=0.95, d_u=0.1, d_l=0.05, fa2=0.3, d_fa=-0.2):
    out = []
    for mix in FR.MIX_FILTERS:
        base = {"subset": "target_vs_interferer", "half": "E", "mixtures": mix}
        out.append({**base, "a": "m1:tap5:cond", "b": None, "auc": _est(auc), "fa_at_miss2": _est(fa2),
                    "fa_at_miss1": _est(fa2 + 0.1)})
        out.append({**base, "a": "m1:tap5:cond", "b": "m1:tap5:uncond", "auc": _est(d_u, d_u - 0.02, d_u + 0.02),
                    "fa_at_miss2": _est(d_fa, d_fa - 0.05, d_fa + 0.05)})
        out.append({**base, "a": "m1:tap5:cond", "b": "logmel:tap0:cond", "auc": _est(d_l, d_l - 0.02, d_l + 0.02),
                    "fa_at_miss2": _est(0.0, -0.1, 0.1)})
    return out


class TestViability(unittest.TestCase):
    def test_gate(self):
        self.assertTrue(FR.viability(fake_results(), "m1", "tap5")["continue_to_harness"])
        # reviewer's counterexample: AUC 0.90 but no useful low-miss rejection
        self.assertFalse(FR.viability(fake_results(auc=0.90, fa2=1.0, d_fa=0.0), "m1", "tap5")["continue_to_harness"])
        self.assertFalse(FR.viability(fake_results(d_u=0.03), "m1", "tap5")["continue_to_harness"])
        self.assertFalse(FR.viability(fake_results(d_l=0.01), "m1", "tap5")["continue_to_harness"])  # CI touches 0
        self.assertFalse(FR.viability(fake_results(auc=0.89), "m1", "tap5")["continue_to_harness"])
        self.assertFalse(FR.viability(fake_results(fa2=0.55), "m1", "tap5")["continue_to_harness"])
        self.assertFalse(FR.viability(fake_results(d_fa=-0.03), "m1", "tap5")["continue_to_harness"])
        v = FR.viability(fake_results(), "m1", "tap5")
        self.assertIn("cross_project", v)
        self.assertEqual(v["cross_project"]["c_auc"]["value"], 0.95)


class TestFrameReport(unittest.TestCase):
    def z(self):
        return {"labels": np.array([0, 1, 2, 3, 2, 1, 1, 2, 2, 1], np.uint8),
                "lengths": np.array([4, 4, 2]),
                "target_speaker": np.array(["7", "5", "9"]),
                "interferer_speaker": np.array(["5", "7", "7"]),
                "same_sex": np.array([True, False, True]),
                "target_session": np.array(["cross_project", "same_chapter", "cross_project"]),
                "half_S": np.array(["9"]), "half_E": np.array(["5", "7"])}

    def test_frame_items(self):
        idx, y, gt, gj, n = FR.frame_items(self.z(), "target_vs_interferer")
        np.testing.assert_array_equal(idx, [1, 2, 3, 4, 5, 6, 7, 8, 9])
        np.testing.assert_array_equal(y, [1, 0, 1, 0, 1, 1, 0, 0, 1])
        np.testing.assert_array_equal(gt, [1, 1, 1, 0, 0, 0, 0, 2, 2])  # groups: "5", "7", "9"
        np.testing.assert_array_equal(gj, [0, 0, 0, 1, 1, 1, 1, 1, 1])
        self.assertEqual(n, 3)
        idx, y, _, _, _ = FR.frame_items(self.z(), "overlap_vs_interferer", mixtures="same_sex")
        np.testing.assert_array_equal(idx, [2, 3, 8])
        idx, *_ = FR.frame_items(self.z(), "target_vs_interferer", mixtures="cross_project")
        np.testing.assert_array_equal(idx, [1, 2, 3, 8, 9])  # mixture 2's target is same_chapter
        with self.assertRaises(ValueError):
            FR.frame_items(self.z(), "target_vs_interferer", mixtures="bogus")

    def test_halves(self):
        idx, _, gt, gj, n = FR.frame_items(self.z(), "target_vs_interferer", "E")
        np.testing.assert_array_equal(idx, [1, 2, 3, 4, 5, 6, 7])  # mixture 3 has speaker 9 (half S)
        self.assertEqual(n, 2)
        idx, *_ = FR.frame_items(self.z(), "target_vs_interferer", "S")
        self.assertEqual(idx.size, 0)  # its interferer "7" is not in S


if __name__ == "__main__":
    unittest.main()
