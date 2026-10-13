import unittest

# Importable both as `tests.<module>` (-t) and as a top-level module (-s only).
_ROOT = str(__import__("pathlib").Path(__file__).resolve().parents[1])  # linux/tools/learned-bias
if _ROOT not in __import__("sys").path:
    __import__("sys").path.insert(0, _ROOT)

from learned_bias.splits import spgi_is_dev, subset_calls


class SplitTests(unittest.TestCase):
    def test_spgi_dev_split_pinned(self):
        # Shared with Rust: ids formatted as {i:032x}.
        ids = [f"{i:032x}" for i in range(0x16)]
        dev = [c for c in ids if spgi_is_dev(c)]
        self.assertEqual(dev[:3], [f"{0x0b:032x}", f"{0x10:032x}", f"{0x15:032x}"])
        self.assertFalse(spgi_is_dev("abc"))

    def test_learning_curve_subsets_are_nested(self):
        # Namespaced dataset/session ids, as the shards' metadata gives them.
        calls = [f"spgispeech/call{i}" for i in range(61)] + [f"icsi/Bmr{i:03d}" for i in range(40)]
        s25, s50, s100 = (subset_calls(calls, f, 20261011) for f in (0.25, 0.5, 1.0))
        self.assertEqual((len(s25), len(s50), len(s100)), (26, 51, 101))
        self.assertTrue(s25 <= s50 <= s100)
        self.assertEqual(s25, subset_calls(list(reversed(calls)), 0.25, 20261011))


if __name__ == "__main__":
    unittest.main()
