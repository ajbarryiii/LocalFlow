"""The scorer evaluation path must stay bit-identical while the front-end
evaluator is added (DESIGN.md 14.2 fe-15).

1. A digest of `evaluate.compute_metrics` on the synthetic fixture of
   test_W0_evaluate, with seeded random scores (tau calibration, bootstrap,
   cross-fit, frame statistics, re-aligned WER), pinned at 5f795f8's scorer
   path (the last commit touching evaluate/metrics/align/refs before W0F).
2. The frozen dev-v1 / test-v1 hashes (NOTES): HASH equals the recorded value
   and the SHA-256 of CONTENT.sha256. Only the listing files are read.
"""

import hashlib
import json
import unittest
from pathlib import Path

import numpy as np

from lfspk import paths
from lfspk.harness import evaluate as E
from tests import test_W0_evaluate as TE

PINNED_METRICS_SHA256 = "ea150eb5dfe60d7ae4bd7e2ee4c1c3052dbc469a18eb75862c8173962ff1a8b7"
FROZEN = {"dev-v1": "6d5fd40a4704a810b59295647be6d68a5cbe4c7f1ec210b890351e7441bf8638",
          "test-v1": "c4a27094c5e3326e0edfb21262e14d952e41dd4779f0062ce8ffa04374ca3f05"}


def _canonical(obj) -> str:
    def fix(x):
        if isinstance(x, dict):
            return {str(k): fix(v) for k, v in x.items()}
        if isinstance(x, (list, tuple)):
            return [fix(v) for v in x]
        if isinstance(x, (np.floating, float)):
            x = float(x)
            return repr(x) if not np.isfinite(x) else x
        if isinstance(x, np.integer):
            return int(x)
        return x

    return json.dumps(fix(obj), sort_keys=True, separators=(",", ":"))


def scorer_metrics_digest() -> str:
    fx = TE.EvaluatorTest("test_budget_and_cis")
    fx.setUp()
    try:
        rng = np.random.default_rng(1234)
        out = Path(fx._tmp.name) / "r"
        fx._scores(out, lambda lab: np.clip(((lab == 1) | (lab == 3)) * 0.7 + rng.random(lab.size) * 0.4, 0, 1).astype(np.float32))
        res = E.compute_metrics("fake", out, "all", "x", boot=100, fs=fx.fs, words=fx.words)
    finally:
        fx.tearDown()
    return hashlib.sha256(_canonical(res).encode()).hexdigest()


class ScorerPathRegressionTest(unittest.TestCase):
    def test_compute_metrics_digest_unchanged(self):
        self.assertEqual(scorer_metrics_digest(), PINNED_METRICS_SHA256)

    def test_frozen_hashes_unchanged(self):
        root = paths.DATA / "harness" / "sets"
        if not (root / "dev-v1" / "HASH").exists():
            self.skipTest("data mount not available")
        for set_id, h in FROZEN.items():
            d = root / set_id
            self.assertEqual((d / "HASH").read_text().strip(), h)
            self.assertEqual(hashlib.sha256((d / "CONTENT.sha256").read_bytes()).hexdigest(), h)


if __name__ == "__main__":
    print(scorer_metrics_digest())
