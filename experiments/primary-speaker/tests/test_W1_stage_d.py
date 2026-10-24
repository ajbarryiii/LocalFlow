"""W1 Stage D: grid and the pre-registered selection rule (synthetic points)."""

import unittest

from lfspk.embed import stage_d as D


def _paired(diffs):
    def f(a, b):
        lo, hi = diffs[(a, b)]
        return {"point": (lo + hi) / 2, "lo": lo, "hi": hi}
    return f


class GridTest(unittest.TestCase):
    def test_48_unique_configs(self):
        g = D.grid()
        self.assertEqual(len(g), 48)
        self.assertEqual(len({c.name for c in g}), 48)
        self.assertEqual(g[0].kwargs(64)["cache"], "64")
        self.assertEqual(g[0].kwargs(0)["rule"], "robust")


class SelectRuleTest(unittest.TestCase):
    points = {"big": 0.10, "mid": 0.12, "small": 0.20, "tiny": 0.30}
    costs = {"big": 100.0, "mid": 40.0, "small": 10.0, "tiny": 5.0}

    def test_cheapest_not_significantly_worse_is_selected(self):
        diffs = {("tiny", "big"): (0.10, 0.30), ("small", "big"): (0.02, 0.15), ("mid", "big"): (-0.01, 0.05)}
        r = D.select_rule(self.points, self.costs, _paired(diffs))
        self.assertEqual(r["b0"], "big")
        self.assertEqual(r["selected"], "mid")
        self.assertEqual([c["name"] for c in r["comparisons"]], ["tiny", "small", "mid"])  # cost order, stops early
        self.assertEqual(r["cheaper"], {"0.5": "small", "0.15": "tiny"})  # c <= 20: small, tiny; c <= 6: tiny

    def test_b0_selected_when_everything_cheaper_is_worse(self):
        diffs = {(n, "big"): (0.01, 0.2) for n in ("tiny", "small", "mid")}
        r = D.select_rule(self.points, self.costs, _paired(diffs))
        self.assertEqual(r["selected"], "big")
        self.assertEqual(r["cheaper"]["0.5"], "mid")  # 40 <= 50: lowest m among cheap enough
        self.assertEqual(r["cheaper"]["0.15"], "small")  # c <= 15: small (10) and tiny (5); lowest m is small

    def test_empty_cheaper_set(self):
        r = D.select_rule({"a": 0.1, "b": 0.2}, {"a": 1.0, "b": 0.9}, _paired({("b", "a"): (-0.1, 0.3)}))
        self.assertEqual(r["selected"], "b")
        self.assertEqual(r["cheaper"], {"0.5": None, "0.15": None})

    def test_mismatched_inputs(self):
        with self.assertRaises(ValueError):
            D.select_rule({"a": 0.1}, {"b": 1.0}, _paired({}))


if __name__ == "__main__":
    unittest.main()


class StageDR1RegressionTest(unittest.TestCase):
    def test_invalid_costs_rejected(self):
        pts = {"a": 0.1, "b": 0.2}
        for bad in (float("nan"), float("inf"), 0.0, -1.0):
            with self.assertRaises(ValueError):
                D.select_rule(pts, {"a": bad, "b": 1.0}, _paired({}))

    def test_s0_flag(self):
        self.assertTrue(D.s0_flag({"relative": 0.019, "relative_ci": [0.010, 0.028]}))  # reviewer's case
        self.assertFalse(D.s0_flag({"relative": 0.002, "relative_ci": [-0.004, 0.008]}))

    def test_plan_measures_latency_without_cache(self):
        import argparse
        import contextlib
        import io

        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            D.cmd_plan(argparse.Namespace(set="dev-v1", half="A", workers=8))
        lines = buf.getvalue().splitlines()
        runs = [x for x in lines if " run " in x]
        lat = [x for x in lines if " latency " in x]
        self.assertEqual((len(runs), len(lat)), (48, 48))
        self.assertTrue(all(f"cache={D.CACHE}" in x for x in runs))
        self.assertTrue(all("cache=0" in x and f"cache={D.CACHE}" not in x for x in lat))
        # every latency command sets the evaluator's CPU_ENV exactly (reviewer r2 #1)
        import shlex

        from lfspk.harness.evaluate import CPU_ENV

        for x in lat:
            toks = shlex.split(x)
            self.assertEqual(toks[0], "env")
            env = dict(t.split("=", 1) for t in toks[1:] if "=" in t and not t.startswith("--") and t[0].isupper())
            self.assertEqual({k: env.get(k) for k in CPU_ENV}, CPU_ENV)
