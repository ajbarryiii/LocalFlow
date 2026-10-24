"""W5 training examples (DESIGN section 8) on W0's synthetic corpus."""

from __future__ import annotations

import json
import unittest

import numpy as np
import torch

from lfspk.extract import data
from lfspk.extract.frontend import analytic_mel_power
from lfspk.harness.synthetic import SyntheticCorpus
from lfspk.pvad.enrollment import EnrollmentBank, EnrollPolicy, build_partitions, target_eligible


def synthetic_setup(corpus):
    idx = json.loads((corpus.index_dir / "librispeech-dev.json").read_text())
    utts: dict[str, list[str]] = {}
    chapter_project = {}
    for u in idx["utterances"]:
        utts.setdefault(u["speaker"], []).append(u["id"])
        chapter_project[u["chapter"]] = u["project"]
    parts = build_partitions(utts, chapter_project)
    rng = np.random.default_rng(0)
    rows = {"emb": [], "speaker": [], "utt": [], "channel": [], "contaminated": []}
    for s, p in parts.items():
        if not target_eligible(p):
            continue
        for u in sorted(p.enroll):
            for ch in ("builtin", "headset"):
                for c in (False, True):
                    v = rng.standard_normal(192).astype(np.float32)
                    rows["emb"].append(v / np.linalg.norm(v))
                    rows["speaker"].append(s), rows["utt"].append(u), rows["channel"].append(ch), rows["contaminated"].append(c)
    bank = EnrollmentBank(np.stack(rows["emb"]), np.array(rows["speaker"]), np.array(rows["utt"]),
                          np.array(rows["channel"]), np.array(rows["contaminated"]), "synthetic", "0" * 64)
    return parts, bank, idx["speakers"]


class TestLabels(unittest.TestCase):
    def test_identity_labels(self):
        t = np.array([1, 1, 0, 0, 1], bool)
        i = np.array([0, 1, 1, 0, 0], bool)
        np.testing.assert_array_equal(data.identity_labels(t, i, False, "S4"), i)
        np.testing.assert_array_equal(data.identity_labels(t, i, True, "S4"), t | i)  # absent: every voice is someone else
        np.testing.assert_array_equal(data.identity_labels(t, i, False, "N"), np.zeros(5, bool))
        np.testing.assert_array_equal(data.identity_labels(t, i, True, "N"), t)

    def test_frame_labels(self):
        lab = data.frame_labels(np.array([1, 0, 1], bool), 3 * 160)  # 3 contract frames -> 4 feature frames
        np.testing.assert_array_equal(lab, [1, 0, 1, 0])

    def test_held_out_selection(self):
        from lfspk.pvad.enrollment import SpeakerPartition

        parts = {str(s): SpeakerPartition(str(s), "cross_project", frozenset(), frozenset()) for s in range(1, 201)}
        parts["7"] = SpeakerPartition("7", "same_chapter", frozenset(), frozenset())
        sex = {str(s): "F" if s % 2 else "M" for s in range(1, 201)}
        h = data.held_out_speakers(parts, sex)
        self.assertEqual(len(h), 48)
        self.assertEqual(sum(sex[s] == "F" for s in h), 24)
        self.assertNotIn("7", h)
        self.assertEqual(h, data.held_out_speakers(dict(reversed(list(parts.items()))), sex))
        with self.assertRaises(ValueError):
            data.held_out_speakers({k: v for k, v in list(parts.items())[:30]}, sex)


class TestExamples(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        from lfspk.harness.mix import MixtureGenerator

        cls._ctx = SyntheticCorpus()
        corpus = cls._ctx.__enter__()
        cls.parts, cls.bank, cls.sex = synthetic_setup(corpus)
        eligible = sorted((s for s, p in cls.parts.items() if target_eligible(p)), key=int)
        cls.excluded = ("103",)
        pool = [s for s in sorted(cls.parts, key=int) if s not in cls.excluded]
        cls.gen = MixtureGenerator("dev", corpus=corpus, speakers=pool)
        cls.targets = [s for s in eligible if s not in cls.excluded]

    @classmethod
    def tearDownClass(cls):
        cls._ctx.__exit__(None, None, None)

    def source(self, **kw):
        pol = data.ExamplePolicy(enroll=EnrollPolicy(k_choices=(1, 2, 3)), **kw)
        return data.ExampleSource(self.gen, self.parts, self.bank, self.targets, self.excluded, pol, _synthetic_test=True)

    def test_refuses_non_train_generator(self):
        with self.assertRaises(ValueError):
            data.ExampleSource(self.gen, self.parts, self.bank, self.targets, self.excluded, data.ExamplePolicy())
        with self.assertRaises(ValueError):
            data.ExampleSource(self.gen, self.parts, self.bank, ["103"], self.excluded, data.ExamplePolicy(),
                               _synthetic_test=True)

    def test_families_targets_and_labels(self):
        src = self.source()
        for fam in data.FAMILIES:
            e = src.example(1, 7, family=fam)
            self.assertEqual(e.info["family"], fam)
            self.assertNotIn("103", e.info["interferers"])
            self.assertEqual(len(e.audio), len(e.target))
            if fam in ("S0", "N"):
                np.testing.assert_allclose(e.target, e.audio, atol=1e-6)  # T2, target only: y* = mix
                self.assertFalse(e.interfering.any())
            else:
                self.assertGreater(float(np.abs(e.audio - e.target).max()), 1e-3)
            self.assertLessEqual(float(np.abs(e.audio).max()), 0.95 + 1e-6)

    def test_absent_target(self):
        src = self.source(p_absent=1.0)
        e = src.example(2, 3, family="S0")
        self.assertTrue(e.info["absent"])
        self.assertNotEqual(e.info["impostor"], e.info["speaker"])
        self.assertNotIn(e.info["impostor"], self.excluded)
        self.assertTrue(e.interfering.any())  # the target's own speech is someone else's now
        self.assertLess(float(np.abs(e.target).max()), float(np.abs(e.audio).max()))  # y* = noise only
        t1 = self.source(p_absent=1.0, target_kind="T1").example(2, 3, family="S0")
        self.assertEqual(float(np.abs(t1.target).max()), 0.0)

    def test_n_family_gain_and_peak(self):
        src = self.source()
        for i in range(4):
            e = src.example(3, i, family="N")
            self.assertTrue(0.0 <= e.info["n_gain_db"] <= 15.0)
            self.assertLessEqual(float(np.abs(e.audio).max()), 0.95 + 1e-6)

    def test_n_family_lists_only_present_speakers(self):
        # implI2-r1 #2: S1's removed interferers must not count as mixture speakers (bootstrap involvement)
        src = self.source()
        seen_removed = False
        for i in range(6):
            e = src.example(4, i, family="N")
            self.assertEqual(e.info["interferers"], [])
            self.assertEqual(e.meta["interferers"], [])
            np.testing.assert_allclose(e.audio, e.target_image + e.noise, atol=1e-6)
            seen_removed |= bool(e.info["removed_interferers"])
        self.assertTrue(seen_removed)  # the S1 renders did have interferers, now removed
        s1 = src.example(4, 0, family="S1")
        self.assertTrue(s1.info["interferers"])
        self.assertEqual(s1.info["removed_interferers"], [])

    def test_determinism_and_independent_streams(self):
        a = self.source().example(5, 11)
        b = self.source().example(5, 11)
        np.testing.assert_array_equal(a.audio, b.audio)
        np.testing.assert_array_equal(a.profile, b.profile)
        c = self.source(target_kind="T1").example(5, 11)
        np.testing.assert_array_equal(a.audio, c.audio)  # same mixture whatever the target kind
        self.assertEqual(a.info["absent"], c.info["absent"])
        u = data.ExampleSource(self.gen, self.parts, self.bank, self.targets, self.excluded, data.ExamplePolicy(
            enroll=EnrollPolicy(k_choices=(1, 2, 3))), conditioned=False, _synthetic_test=True).example(5, 11)
        np.testing.assert_array_equal(a.audio, u.audio)
        self.assertEqual(float(np.abs(u.profile).max()), 0.0)

    def test_prepare_batch(self):
        src = self.source()
        exs = [src.example(9, i, family=f) for i, f in enumerate(("S0", "S4", "S2"))]
        b = data.prepare_batch(exs, analytic_mel_power(), 300, np.random.default_rng(0))
        self.assertEqual(b["x"].shape, (3, 128, 300))
        self.assertEqual(b["ideal"].shape, (3, 128, 300))
        self.assertEqual(b["profile"].shape, (3, 192))
        v0 = b["valid"][0].bool()
        self.assertTrue(torch.all(b["ideal"][0][:, v0] > -1e-4))  # S0, T2: ideal mask is 1
        self.assertLess(float(b["ideal"][1].min()), -1.0)  # S4: something to remove
        self.assertTrue(torch.all(b["x"][:, :, ~b["valid"][0].bool()][0] == 0) if (~v0).any() else True)


if __name__ == "__main__":
    unittest.main()
