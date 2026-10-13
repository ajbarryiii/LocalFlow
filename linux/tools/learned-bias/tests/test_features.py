import math
import unittest

import numpy as np
import torch

# Importable both as `tests.<module>` (-t) and as a top-level module (-s only).
_ROOT = str(__import__("pathlib").Path(__file__).resolve().parents[1])  # linux/tools/learned-bias
if _ROOT not in __import__("sys").path:
    __import__("sys").path.insert(0, _ROOT)

from learned_bias import BLANK, V
from learned_bias.features import candidate_features, g_size, logit_features, trie_features
from learned_bias.fixtures import trie_arrays
from learned_bias.trie import BiasTrie


class TrieFeatureTests(unittest.TestCase):
    def test_end_with_longer_phrase_through_it(self):
        # "new york" and "new york city": the "york" node ends a phrase and
        # has a longer one through it.
        t = trie_arrays(BiasTrie([[1, 2], [1, 2, 3]]))
        np.testing.assert_array_equal(t["token"], [BLANK, 1, 2, 3])
        np.testing.assert_array_equal(t["depth"], [0, 1, 2, 3])
        np.testing.assert_array_equal(t["is_end"], [False, False, True, True])
        np.testing.assert_array_equal(t["dmin"], [2, 1, 0, 0])
        np.testing.assert_array_equal(t["dmax"], [3, 2, 1, 0])
        np.testing.assert_array_equal(t["nends"], [2, 2, 2, 1])
        np.testing.assert_allclose(
            t["nf"][2], [2 / 8, 1.0, 0.0, 1 / 8, math.log(3) / 4], rtol=1e-6
        )
        # The root uses the same formulas over the whole trie.
        np.testing.assert_allclose(
            t["nf"][0], [0.0, 0.0, 2 / 8, 3 / 8, math.log(3) / 4], rtol=1e-6
        )
        self.assertEqual(t["nf"].dtype, np.float32)

    def test_branching_counts(self):
        t = trie_arrays(BiasTrie([[1, 2], [1, 3, 4], [5]]))
        # states: 0 root, 1 "1", 2 "1 2", 3 "1 3", 4 "1 3 4", 5 "5"
        np.testing.assert_array_equal(t["dmin"], [1, 1, 0, 1, 0, 0])
        np.testing.assert_array_equal(t["dmax"], [3, 2, 0, 1, 0, 0])
        np.testing.assert_array_equal(t["nends"], [3, 2, 1, 1, 1, 1])
        np.testing.assert_array_equal(t["parent"], [-1, 0, 1, 1, 3, 0])

    def test_empty_trie_root(self):
        t = trie_features([BLANK], [-1], [False])
        np.testing.assert_array_equal(t["nf"], [[0, 0, 0, 0, 0]])

    def test_dmax_capped_at_32(self):
        t = trie_arrays(BiasTrie([list(range(40))]))
        self.assertEqual(t["dmax"][0], 32)
        self.assertEqual(t["dmax"][8], 32)
        self.assertEqual(t["dmax"][9], 31)
        self.assertEqual(t["dmin"][0], 40)  # dmin is not capped
        self.assertAlmostEqual(float(t["nf"][0, 3]), 4.0)

    def test_g_size(self):
        self.assertAlmostEqual(float(g_size(0)), 0.0)
        self.assertAlmostEqual(float(g_size(1000)), math.log(1001) / 7, places=6)


class LogitFeatureTests(unittest.TestCase):
    def test_definitions_over_token_rows_only(self):
        rng = np.random.default_rng(3)
        rows = rng.normal(0, 4, size=(2, V + 5)).astype(np.float32)
        rows[0, V:] = 1e4  # durations must be ignored
        rows[1, BLANK] = rows[1, :V].max() + 1  # blank can be the max
        l = torch.from_numpy(rows)
        dec = torch.tensor([0, 0, 1, 1])
        tok = torch.tensor([7, BLANK, 3, 1000])
        lf = logit_features(l, dec, tok).numpy()
        self.assertEqual(lf.dtype, np.float32)
        for k, (d, y) in enumerate(zip(dec.tolist(), tok.tolist())):
            r = rows[d, :V].astype(np.float64)
            mx = r.max()
            lse = mx + math.log(np.exp(r - mx).sum())
            want = [r[y] / 10, (r[y] - mx) / 10, (r[y] - lse) / 10, (r[BLANK] - lse) / 10]
            np.testing.assert_allclose(lf[k], want, rtol=1e-6, atol=1e-7)

    def test_candidate_feature_layout(self):
        nf = torch.arange(15, dtype=torch.float32).view(3, 5)
        l = torch.zeros(1, V)
        x = candidate_features(nf, l, torch.tensor([0, 0]), torch.tensor([4, 9]), torch.tensor([2, 1]), 0.25)
        self.assertEqual(tuple(x.shape), (2, 10))
        np.testing.assert_array_equal(x[0, :5].numpy(), nf[2].numpy())
        np.testing.assert_array_equal(x[1, :5].numpy(), nf[1].numpy())
        self.assertTrue(torch.all(x[:, 9] == 0.25))
        # Uniform logits: lf = [0, 0, -ln(1025)/10, -ln(1025)/10].
        np.testing.assert_allclose(x[0, 5:9].numpy(), [0, 0, -math.log(V) / 10, -math.log(V) / 10], rtol=1e-6)


if __name__ == "__main__":
    unittest.main()
