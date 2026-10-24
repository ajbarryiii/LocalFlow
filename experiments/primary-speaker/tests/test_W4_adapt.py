"""W4 adaptation rules and vote-count protection on synthetic embeddings."""

from __future__ import annotations

import unittest

import numpy as np

from lfspk.protect import adapt
from lfspk.protect.transforms import build, l2n

from tests.test_W4_experiment import synth


class AdaptTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.train, cls.dev = synth(1)

    def fitted(self, name):
        return build(name, 5).fit(self.train.X, self.train.y, 5)

    def test_zero_noise_snapshot_is_the_true_state(self):
        # review clone-r1 #4: with no noise the latest snapshot must equal the truth
        prot = self.fitted("center+noise0")
        res = adapt.noise_analysis(prot, self.dev, np.random.default_rng(0))
        self.assertAlmostEqual(res["renoise_snapshot_average_cos"][1], 1.0, places=5)

    def test_exact_rule_matches_batch(self):
        prot = self.fitted("lda16")
        E = [self.dev.stack(self.dev.roles[s].E) for s in self.dev.speakers]
        streamed = adapt.run_rules(prot, "exact", E, np.random.default_rng(0))
        for n in adapt.NS:
            batch = prot.protect_from_utterances([e[:n] for e in E])
            np.testing.assert_allclose(streamed[n].astype(float), batch.astype(float), atol=5e-3)

    def test_votes_rule_is_majority_of_vote_protection(self):
        prot = self.fitted("center+sh32")
        votes = self.fitted("center+shv32")
        np.testing.assert_array_equal(prot.encoder.H, votes.encoder.H)
        E = [self.dev.stack(self.dev.roles[s].E) for s in self.dev.speakers]
        out = adapt.run_rules(prot, "votes", E, np.random.default_rng(0))
        frac = votes.protect_from_utterances([e[:10] for e in E])
        np.testing.assert_array_equal(out[10], (frac >= 0.5).astype(np.uint8))
        self.assertEqual(len(votes.to_bytes(frac[0])), 64)

    def test_stochastic_rounding_is_unbiased(self):
        prot = self.fitted("center+q2")
        enc = prot.encoder
        L = 2 ** enc.bits
        rng = np.random.default_rng(0)
        v = prot.base.forward(self.dev.stack(self.dev.roles[self.dev.speakers[0]].E[:1]))
        T = enc.encode(prot.base.project(v))
        target = (1 * (((T + 0.5) / L * 2 - 1) * enc.scale) + v) / 2
        draws = np.stack([adapt.quant_update(enc, T, 1, v, rng) for _ in range(4000)]).astype(float)
        mean_level = draws.mean(0)
        expected = (np.clip(target / enc.scale, -1, 1) + 1) / 2 * L - 0.5
        inside = (expected > 0) & (expected < L - 1)
        np.testing.assert_allclose(mean_level[inside], expected[inside], atol=0.05)


if __name__ == "__main__":
    unittest.main()
