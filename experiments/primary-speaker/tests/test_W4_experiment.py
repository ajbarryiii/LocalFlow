"""W4 experiment plumbing end to end on synthetic embeddings (no audio, no cache)."""

from __future__ import annotations

import math
import unittest

import numpy as np

from lfspk.protect import roles
from lfspk.protect.data import DevSet, TrainSet
from lfspk.protect.invert_exp import Config, evaluate_protection, inversion_metrics, summary_row
from lfspk.protect.transforms import l2n

D = 24


def synth(seed: int, n_train: int = 80, n_dev: int = 8):
    rng = np.random.default_rng(seed)
    gm = rng.standard_normal(D)

    def spk_mean():
        return l2n(rng.standard_normal(D) + 1.5 * l2n(gm))

    def utts(m, n, noise):
        return l2n(m + noise * rng.standard_normal((n, D)) / math.sqrt(D))

    Xs, ys, sex = [], [], {}
    for i in range(n_train):
        s = str(5000 + i)
        Xs.append(utts(spk_mean(), 15, 0.8))
        ys += [s] * 15
        sex[s] = "F" if i % 2 else "M"
    train = TrainSet(np.vstack(Xs), np.array(ys), sex, {"synthetic": True})

    speakers, dsex, role_map, full, crop = [], {}, {}, {}, {}
    for i in range(n_dev):
        s = str(100 + i)
        speakers.append(s)
        dsex[s] = "F" if i % 2 else "M"
        m = spk_mean()
        # two chapters (24 + 16); even speakers record them in two projects
        # (project separation), odd speakers in one (chapter separation)
        ch = lambda j: "1" if j < 24 else "2"
        proj = lambda j: f"{i}{ch(j)}" if i % 2 == 0 else f"{i}"
        us = [roles.Utt(f"{s}-{ch(j)}-{j:04d}", s, ch(j), 6 * 16000, proj(j)) for j in range(40)]
        role_map[s] = roles.assign_dev_roles(us, 3)
        F, C = utts(m, 40, 0.8), utts(m, 40, 1.6)
        for j, u in enumerate(us):
            full[u.id], crop[u.id] = F[j], C[j]
    return train, DevSet(speakers, dsex, role_map, full, crop, {"synthetic": True})


class ExperimentTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.train, cls.dev = synth(0)
        cls.cfg = Config(per_speaker=3, per_speaker_linfn=2, n_boot=30, mlp_epochs=5, mlp_seeds=(0,))

    def run_one(self, name):
        return evaluate_protection(name, self.train, self.dev, self.cfg, log=lambda *_: None)

    def test_raw_is_fully_invertible_and_identifies(self):
        r = self.run_one("raw")
        self.assertAlmostEqual(r["attackers"]["analytic"]["cos_true"]["mean"], 1.0, places=5)
        self.assertEqual(r["selected"]["top1_dev"]["mean"], 1.0)
        self.assertIn(r["selected_attacker"], ("analytic", "ridge", "knn10", "mlp-s0"))
        self.assertEqual(r["stored_bytes"], 4 * D)
        u = r["utility"]["k10_crop"]["all"]
        self.assertLessEqual(u["eer_ci"][0], u["eer"])
        self.assertLessEqual(u["eer"], u["eer_ci"][1])
        self.assertEqual(len(summary_row(r)), 15)

    def test_sep_project_and_fixed_gallery(self):
        r = self.run_one("raw")
        self.assertIn("sep_project", r["utility"]["k10_crop"])
        self.assertIsNotNone(r["attackers"]["ridge"]["sep_project"])
        self.assertEqual({self.dev.roles[s].separation for s in self.dev.speakers}, {"project", "chapter"})
        # r2 #5: one cyclic confuser per query -> top-1 is 0 and its CI must be [0, 0]
        n = len(self.dev.speakers)
        R = self.dev.r_centroids()
        est = R[(np.arange(n) + 1) % n] + 1e-3 * R
        m = inversion_metrics(est, self.dev, R, R, R[:0], 0.5, 50)
        self.assertEqual(m["top1_dev"]["mean"], 0.0)
        self.assertEqual(m["top1_dev"]["hi"], 0.0)
        self.assertEqual(m["gallery_dev"], n)

    def test_extra_targets_are_evaluated_without_refitting(self):
        _, other = synth(7)  # a disjoint synthetic target set
        r = evaluate_protection("lda16", self.train, self.dev, self.cfg, log=lambda *_: None,
                                extra={"clone_eval": other})
        ex = r["extra"]["clone_eval"]
        self.assertEqual(ex["n_targets"], len(other.speakers))
        self.assertIn(r["selected_attacker"], ex["attackers"])
        self.assertEqual(ex["selected"], ex["attackers"][r["selected_attacker"]])
        self.assertEqual(ex["selected"]["gallery_dev"], len(other.speakers))
        base = evaluate_protection("lda16", self.train, self.dev, self.cfg, log=lambda *_: None)
        # dev results do not change when extra targets are added
        self.assertEqual(base["utility"], r["utility"])
        self.assertEqual(base["selected_attacker"], r["selected_attacker"])

    def test_keyrot_control(self):
        r = self.run_one("keyrot")
        self.assertAlmostEqual(r["attackers"]["analytic"]["cos_true"]["mean"], 1.0, places=5)
        self.assertLess(r["attackers"]["wrongkey"]["cos_true"]["mean"], 0.9)

    def test_low_bit_protection_loses_information(self):
        raw = self.run_one("raw")
        sh = self.run_one("center+sh32")
        self.assertEqual(sh["stored_bytes"], 4)
        self.assertLess(sh["selected"]["cos_true"]["mean"], raw["selected"]["cos_true"]["mean"])

    def test_linfn_runs(self):
        r = self.run_one("linfn")
        self.assertEqual(r["stored_bytes"], 4 * (D + 1))
        self.assertIn("ridge", r["attackers"])


if __name__ == "__main__":
    unittest.main()
