"""Tests for the noise-only twin sets (W5 DESIGN 9.4) on synthetic data."""

import unittest

import numpy as np

from lfspk.harness.mix import MixtureGenerator
from lfspk.harness.synthetic import SyntheticCorpus
from lfspk.harness.util import active_level_db, mean_level_db


class NoiseGroupTest(unittest.TestCase):
    def test_paired_with_s0_and_snr_holds(self):
        specs = [{"family": f, "snr_db": float(x)} for f in ("noise", "music") for x in (20, 10, 5, 0)]
        with SyntheticCorpus() as corpus:
            gen = MixtureGenerator("dev", corpus)
            u = corpus.utterances["101"][0]
            from lfspk.harness.mix import SCENARIOS

            s0 = gen.render_paired(SCENARIOS, 11, target=u)["S0"]
            group = gen.render_noise_group(11, u, specs)
            self.assertEqual(len(group), 8)
            for sp, m in zip(specs, group):
                self.assertEqual(m.meta["scenario"], "N")
                self.assertEqual({k: m.meta["noise_spec"][k] for k in sp}, sp)
                self.assertEqual(m.meta["peak_gain_db"], s0.meta["peak_gain_db"])
                self.assertLessEqual(float(np.abs(m.audio).max()), 0.95 + 1e-6)
                self.assertFalse(np.any(m.labels >= 2))
                np.testing.assert_array_equal(m.labels, s0.labels)
                self.assertEqual(m.meta["room"], s0.meta["room"])
                self.assertEqual(m.meta["target"]["level_dbfs"], s0.meta["target"]["level_dbfs"])
                np.testing.assert_array_equal(m.target, s0.target)  # always, whatever the gain (noise-r1 #1)
                lt = active_level_db(m.target, m.target_active)
                # The S0 background is bit-identical; only the added source is scaled (noise-r2 #1).
                np.testing.assert_array_equal(m.noise_parts["ambience"], s0.noise_parts["ambience"])
                np.testing.assert_array_equal(m.noise_parts["self"], s0.noise_parts["self"])
                np.testing.assert_allclose(m.noise, s0.noise + m.noise_parts["event"], atol=1e-6)
                self.assertAlmostEqual(lt - mean_level_db(m.noise_parts["event"]), sp["snr_db"], places=2)
                self.assertAlmostEqual(m.meta["noise_spec"]["snr_measured_db"], sp["snr_db"], places=2)
                self.assertEqual(m.meta["noise_spec"]["inherited_ambience_snr_db"], s0.meta["ambience"]["snr_db"])
                self.assertGreater(float(np.abs(m.noise_parts["event"]).max()), 0.0)  # the family component is there
                np.testing.assert_allclose(m.audio, m.target + m.noise, atol=1e-6)
            # One MUSAN source per family across its SNRs.
            for fam in ("noise", "music"):
                ids = {m.meta["event"]["id"] for m in group if m.meta["noise_spec"]["family"] == fam}
                self.assertEqual(len(ids), 1)
            # Noise grows as SNR falls, within a family.
            lv = [mean_level_db(m.noise) for m in group[:4]]
            self.assertTrue(all(a < b for a, b in zip(lv, lv[1:])))
            # Deterministic.
            again = gen.render_noise_group(11, u, specs)
            for a, b in zip(group, again):
                np.testing.assert_array_equal(a.audio, b.audio)


class NonUnitGainTest(unittest.TestCase):
    def test_target_identical_when_the_paired_group_is_limited(self):
        import lfspk.harness.mix as mixmod
        from lfspk.harness.mix import SCENARIOS

        with SyntheticCorpus() as corpus:
            gen = MixtureGenerator("dev", corpus)
            u = corpus.utterances["102"][0]
            old = mixmod.TARGET_LEVEL_DBFS
            mixmod.TARGET_LEVEL_DBFS = (-3.0, -2.0)  # force the paired limiter to act
            try:
                ref = gen.render_paired(SCENARIOS, 5, target=u)["S0"]
                self.assertLess(ref.meta["peak_gain_db"], 0.0)
                specs = [{"family": "noise", "snr_db": 10.0}, {"family": "music", "snr_db": 0.0}]
                for m in gen.render_noise_group(5, u, specs):
                    np.testing.assert_array_equal(m.target, ref.target)
                    self.assertEqual(m.meta["peak_gain_db"], ref.meta["peak_gain_db"])
                    self.assertLessEqual(float(np.abs(m.audio).max()), 0.95 + 1e-6)
            finally:
                mixmod.TARGET_LEVEL_DBFS = old


class PeakBoundaryTest(unittest.TestCase):
    def test_written_audio_is_the_checked_array(self):
        # Noise-r3 LOW: with a non-unit gain the written peak must not exceed the limit.
        import lfspk.harness.mix as mixmod
        from lfspk.harness.mix import SCENARIOS

        with SyntheticCorpus() as corpus:
            gen = MixtureGenerator("dev", corpus)
            old = mixmod.TARGET_LEVEL_DBFS
            mixmod.TARGET_LEVEL_DBFS = (-3.0, -2.0)
            try:
                for seed in range(4):
                    u = corpus.utterances["103"][seed % 3]
                    ref = gen.render_paired(SCENARIOS, seed, target=u)["S0"]
                    g = np.float32(10 ** (ref.meta["peak_gain_db"] / 20))
                    for m in gen.render_noise_group(seed, u, [{"family": "music", "snr_db": 0.0}, {"family": "noise", "snr_db": 5.0}]):
                        self.assertLessEqual(float(np.abs(m.audio).max()), 0.95)
                        np.testing.assert_array_equal(m.audio, (m.target + m.noise).astype(np.float32))
                        np.testing.assert_array_equal(m.target, ref.target)
                        self.assertNotEqual(float(g), 1.0)
            finally:
                mixmod.TARGET_LEVEL_DBFS = old


class LegacyMetadataTest(unittest.TestCase):
    def test_s0_s4_meta_keys_unchanged(self):
        # Noise-r1 #2: legacy renders carry exactly the keys dev-v1/test-v1 were frozen with.
        legacy = {"split", "scenario", "seed", "attempt", "device", "rir_mode", "device_params", "frames", "samples", "target", "room",
                  "interferers", "ambience", "event", "self_noise_dbfs", "label_fractions", "overlap_of_target", "index_hashes",
                  "peak_gain_db", "paired_with"}
        with SyntheticCorpus() as corpus:
            m = MixtureGenerator("dev", corpus).render("S2", 3)
            self.assertEqual(set(m.meta), legacy)


if __name__ == "__main__":
    unittest.main()
