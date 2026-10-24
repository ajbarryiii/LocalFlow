"""W6 tuning stream (DESIGN 2.4) on synthetic dictations and donors."""

from __future__ import annotations

import unittest

import numpy as np

from lfspk.api import FRAME_SAMPLES, frame_count
from lfspk.personal import stream as ST
from lfspk.personal.signals import db, pact, shift_frames, shift_samples


def _act(nf, spans):
    a = np.zeros(nf, bool)
    for lo, hi in spans:
        a[lo:hi] = True
    return a


def _tone(n, f, amp, rng):
    t = np.arange(n) / 16000.0
    return (amp * np.sin(2 * np.pi * f * t) + 1e-4 * rng.standard_normal(n)).astype(np.float32)


def make_dictation(rng, nf=600, spans=((80, 520),), amp=0.05):
    n = nf * FRAME_SAMPLES
    a = _act(nf, spans)
    tgt = _tone(n, 220, amp, rng) * np.repeat(a, FRAME_SAMPLES).astype(np.float32)
    noise = (1e-3 * rng.standard_normal(n)).astype(np.float32)
    return ST.Dictation((tgt + noise).astype(np.float32), tgt, a)


def make_donor(rng, fam, i, nf=500, t_spans=((50, 400),), i_spans=((100, 300),), sir=6.0, event=True):
    n = nf * FRAME_SAMPLES
    ta, ia = _act(nf, t_spans), _act(nf, i_spans)
    tgt = _tone(n, 300, 0.05, rng) * np.repeat(ta, FRAME_SAMPLES).astype(np.float32)
    itf = _tone(n, 500, 0.02, rng) * np.repeat(ia, FRAME_SAMPLES).astype(np.float32)
    noise = (2e-3 * rng.standard_normal(n)).astype(np.float32)
    ev = (1e-3 * rng.standard_normal(n)).astype(np.float32) if event else np.zeros(n, np.float32)
    # float16 round trip, as the bank stores
    tgt, itf, noise, ev = (x.astype(np.float16).astype(np.float32) for x in (tgt, itf, noise, ev))
    pt = pact(tgt, ta)
    sir_d = db(pt / pact(itf, ia)) if ia.any() else None
    ntr = float(np.mean(noise.astype(np.float64) ** 2)) / pt
    return ST.Donor(fam, i, tgt, itf, noise, ev, ta, ia, sir_d, ntr, {})


class FakeBank:
    def __init__(self, donors):
        self.d = donors
        self.counts = {f: sum(1 for (g, _) in donors if g == f) for f in ("S0", "S1", "S2", "S3", "S4")}

    def get(self, fam, i):
        return self.d[(fam, int(i))]


def fake_bank(seed=0, n=5, empty_first=False):
    rng = np.random.default_rng(seed)
    donors = {}
    for f in ("S0", "S1", "S2", "S3", "S4"):
        for i in range(n):
            if f == "S0":
                donors[(f, i)] = make_donor(rng, f, i, i_spans=(), event=False)
            elif empty_first and i < 2:
                donors[(f, i)] = make_donor(rng, f, i, i_spans=((480, 500),))  # 20 active frames only
            else:
                donors[(f, i)] = make_donor(rng, f, i)
    return FakeBank(donors)


class TestPlacement(unittest.TestCase):
    def setUp(self):
        self.rng = np.random.default_rng(1)
        self.d = make_dictation(self.rng)

    def test_onset_alignment_and_sir(self):
        D = make_donor(self.rng, "S4", 0)
        p = ST.place_present("S4", self.d, D, np.random.default_rng(0))
        self.assertEqual(p.record["shift_frames"], 80 - 50)  # donor onset 50 -> dictation onset 80
        np.testing.assert_array_equal(p.labels, shift_frames(D.interferer_active, 30, 600))
        self.assertLess(abs(p.record["sir_measured_db"] - D.sir_db), 1e-3)
        # mix = y + scaled placed interference, y = d
        np.testing.assert_allclose(p.mix, p.y + p.interf, atol=1e-7)
        np.testing.assert_array_equal(p.y, self.d.audio)

    def test_level_measured_after_placement(self):
        # half the donor's interference falls outside the dictation window; the SIR is still matched in-window
        D = make_donor(self.rng, "S2", 0, nf=900, t_spans=((50, 800),), i_spans=((100, 300), (560, 800)))
        D.interf[(560 + 30) * FRAME_SAMPLES:] *= 4  # the cut-off part is louder
        p = ST.place_present("S2", self.d, D, np.random.default_rng(0))
        self.assertLess(abs(p.record["sir_measured_db"] - D.sir_db), 1e-3)

    def test_s1_event_separate_gain(self):
        D = make_donor(self.rng, "S1", 0)
        p = ST.place_present("S1", self.d, D, np.random.default_rng(0))
        g = p.record["g"]
        ev = g * shift_samples(D.event, p.record["shift_frames"] * FRAME_SAMPLES, len(self.d.audio))
        np.testing.assert_allclose(p.y, self.d.audio + ev, atol=1e-7)
        np.testing.assert_allclose(p.mix, self.d.audio + p.interf + ev, atol=1e-7)
        # g is derived from speech interference only: the event does not change it
        D2 = make_donor(np.random.default_rng(1), "S1", 0)
        D2.event = D2.event * 10
        p2 = ST.place_present("S1", make_dictation(np.random.default_rng(1)), D2, np.random.default_rng(0))
        p1 = ST.place_present("S1", make_dictation(np.random.default_rng(1)), make_donor(np.random.default_rng(1), "S1", 0),
                              np.random.default_rng(0))
        self.assertEqual(p1.record["g"], p2.record["g"])

    def test_empty_activity_rejected(self):
        D = make_donor(self.rng, "S4", 0, t_spans=((50, 400),), i_spans=((600, 640),))  # placed beyond the window
        with self.assertRaises(ST.Rejected):
            ST.place_present("S4", self.d, D, np.random.default_rng(0))

    def test_n_present_full_window(self):
        # DESIGN 2.4: the placed noise's power over the WHOLE dictation window (padding included) relative to
        # Pact(d.target; a_d) equals the donor's noise-to-target ratio, raised by the U[0, 15] dB draw.
        for nf in (300, 600, 900):  # shorter (zero-padded), equal and longer (cut) donors
            D = make_donor(np.random.default_rng(nf), "S1", 0, nf=nf, t_spans=((50, 250),), i_spans=((60, 200),))
            p = ST.place_present("N", self.d, D, np.random.default_rng(3))
            np.testing.assert_array_equal(p.mix, p.y)
            self.assertFalse(p.labels.any())
            gdb = p.record["n_gain_db"]
            self.assertTrue(0 <= gdb <= 15)
            added = (p.mix - self.d.audio).astype(np.float64)
            self.assertEqual(len(added), len(self.d.audio))
            want_db = 10 * np.log10(D.ntr * pact(self.d.target, self.d.target_active)) + gdb
            got_db = 10 * np.log10(np.mean(added ** 2))
            self.assertLess(abs(want_db - got_db), 1e-3, nf)


class TestS3Shift(unittest.TestCase):
    def test_minimises_overlap_with_retention(self):
        nf = 600
        a_d = _act(nf, ((100, 200), (300, 400)))  # gap 200-300
        ia = _act(500, ((150, 250),))  # 100 active frames
        fs, ov, kept, c0 = ST.s3_shift(a_d, ia, 0, nf)
        self.assertEqual(c0, 100)
        self.assertEqual(ov, 0)
        self.assertEqual(kept, 100)
        self.assertEqual(fs, 50)  # placed at 200-300, the gap, smallest |shift| with zero overlap
        # retention: shifting the call out of the window is never chosen
        ia2 = _act(500, ((100, 400),))
        fs2, ov2, kept2, _ = ST.s3_shift(a_d, ia2, 0, nf)
        self.assertGreaterEqual(kept2, int(np.ceil(0.9 * 300)))

    def test_tie_break(self):
        nf = 400
        a_d = _act(nf, ((0, 10),))
        ia = _act(400, ((100, 160),))
        fs, ov, _, _ = ST.s3_shift(a_d, ia, 0, nf)
        self.assertEqual((fs, ov), (0, 0))  # every shift has zero overlap: |Delta| = 0 wins

    def test_tie_break_on_registered_shift(self):
        # sol code1-r1 m3: ties go to the smaller |Delta| (Delta = f0 + j), not the smaller |j|
        nf = 400
        a_d = _act(nf, ((50, 100),))
        ia = _act(400, ((200, 260),))
        fs, ov, _, _ = ST.s3_shift(a_d, ia, 50, nf)
        self.assertEqual((fs, ov), (0, 0))
        # equal |Delta|: the smaller Delta wins. Interferer blocks [200, 230) and [240, 270); target frames 215
        # and 254 overlap at Delta = 0; the zero-overlap shifts are Delta in [16, 24] and (-25, -16].
        a_d2 = np.zeros(nf, bool)
        a_d2[[215, 254]] = True
        fs2, ov2, _, _ = ST.s3_shift(a_d2, _act(400, ((200, 230), (240, 270))), 0, nf)
        self.assertEqual((fs2, ov2), (-16, 0))

    def test_rejects_without_enough(self):
        with self.assertRaises(ST.Rejected):
            ST.s3_shift(_act(300, ((0, 300),)), _act(300, ((10, 40),)), 0, 300)


class TestExamples(unittest.TestCase):
    def setUp(self):
        rng = np.random.default_rng(2)
        self.dicts = [make_dictation(rng) for _ in range(10)]
        self.bank = fake_bank()

    def test_rng_initialisation_pinned(self):
        # DESIGN 2.4 / amendment A1: default_rng([seed, int(s), k, tag]), tags family 0 .. gain 4
        r = ST.rngs(0, "2775", 17)
        for name, tag in (("family", 0), ("absent", 1), ("dict", 2), ("donor", 3), ("gain", 4)):
            np.testing.assert_array_equal(r[name].random(4), np.random.default_rng([0, 2775, 17, tag]).random(4))

    def test_weights_match_w5(self):
        from lfspk.extract import data

        self.assertEqual(ST.FAMILIES, data.FAMILIES)
        self.assertEqual(ST.FAMILY_WEIGHTS, data.FAMILY_WEIGHTS)

    def test_deterministic(self):
        for k in range(30):
            a = ST.make_example("2775", k, self.dicts, self.bank)
            b = ST.make_example("2775", k, self.dicts, self.bank)
            np.testing.assert_array_equal(a.mix, b.mix)
            np.testing.assert_array_equal(a.y, b.y)
            self.assertEqual(a.record, b.record)
        c = ST.make_example("639", 0, self.dicts, self.bank)
        self.assertIsNotNone(c.record)

    def test_cases_and_labels(self):
        seen = set()
        for k in range(400):
            p = ST.make_example("2775", k, self.dicts, self.bank)
            r = p.record
            seen.add((r["family"], r["absent"]))
            self.assertEqual(p.labels.shape, (frame_count(len(p.mix)),))
            self.assertLessEqual(float(np.max(np.abs(p.mix))), 0.95 + 1e-6)
            if r["absent"]:
                D = self.bank.get("S1" if r["family"] == "N" else r["family"], r["donor"][1])
                if r["family"] == "N":
                    np.testing.assert_array_equal(p.labels, D.target_active)
                else:
                    np.testing.assert_array_equal(p.labels, D.target_active | D.interferer_active)
            elif r["family"] in ("S0", "N"):
                self.assertFalse(p.labels.any())
                np.testing.assert_array_equal(p.mix, p.y)
            else:
                self.assertTrue(p.labels.any())
        self.assertIn(("S0", False), seen)
        self.assertIn(("S4", False), seen)

    def test_rejection_sequence(self):
        bank = fake_bank(empty_first=True, n=6)
        rej = []
        for k in range(200):
            p = ST.make_example("2775", k, self.dicts, bank)
            if not p.record["absent"] and p.record["family"] in ("S1", "S2", "S4"):
                rej.append(p.record["rejections"])
                self.assertGreaterEqual(p.record["donor"][1], 2)  # the empty donors are never used
        self.assertTrue(any(r > 0 for r in rej))

    def test_prepare_batch_on_examples(self):
        import torch

        from lfspk.extract.data import prepare_batch
        from lfspk.extract.frontend import analytic_mel_power

        prof = np.ones(192, np.float32) / np.sqrt(192)
        exs = [ST.to_example(ST.make_example("2775", k, self.dicts, self.bank), prof) for k in range(4)]
        b = prepare_batch(exs, analytic_mel_power(), 400, np.random.default_rng([0, 0, 99]))
        self.assertEqual(tuple(b["x"].shape), (4, 128, 400))
        self.assertTrue(torch.isfinite(b["ideal"]).all())
        self.assertTrue((b["ideal"] <= 0).all())


if __name__ == "__main__":
    unittest.main()


class TestShortDictation(unittest.TestCase):
    """Erratum E1: 2.2-2.7 s tuning dictations through every family, the S3 retention path and N levelling."""

    def test_short_dictation_stream(self):
        rng = np.random.default_rng(9)
        short = make_dictation(rng, nf=220, spans=((30, 200),))  # 2.2 s, 170 active frames
        dicts = [short] + [make_dictation(rng) for _ in range(9)]
        bank = fake_bank(n=6)
        seen = set()
        for k in range(600):
            p = ST.make_example("497", k, dicts, bank)
            r = p.record
            if r.get("dictation") != 0 or r["absent"]:
                continue
            seen.add(r["family"])
            self.assertEqual(len(p.mix), len(short.audio))
            if r["family"] in ("S1", "S2", "S3", "S4"):
                self.assertGreaterEqual(r["interf_active_frames"], 50)
                self.assertLess(abs(r["sir_measured_db"] - r["sir_target_db"]), 1e-3)
            if r["family"] == "S3":
                need = max(50, int(np.ceil(0.9 * r["s3_baseline_frames"])))
                self.assertGreaterEqual(r["interf_active_frames"], need)
        self.assertTrue({"S1", "S3", "S4", "N"} <= seen, seen)
