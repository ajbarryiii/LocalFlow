"""End-to-end contract of stage 2b on synthetic features: verify.score_system
writes score matrices whose trials follow the dev plan, and report.main turns
them into EER/minDCF with CIs and the pre-stated comparisons."""

import json
import tempfile
import unittest
from pathlib import Path

import numpy as np

from lfspk.probe import report, verify
from lfspk.probe.select import LENGTHS


def write_feats(root: Path, name: str, split: str, items, selection, feats):
    d = root / name / split
    d.mkdir(parents=True)
    np.save(d / "features.npy", feats.astype(np.float16))
    (d / "index.json").write_text(json.dumps(items))
    (d / "selection.json").write_text(json.dumps(selection))
    (d / "meta.json").write_text(json.dumps({"limit": 0, "batch_invariance_max_rel": {name: 1e-7}}))


def make_world(root: Path, name: str, n_taps: int, signal_tap: int, rng):
    """Speaker identity lives only in `signal_tap`; other taps are noise."""
    dim = 16
    centres = {}

    def feat(spk, rng):
        if spk not in centres:
            centres[spk] = rng.normal(size=dim) * 3
        out = rng.normal(size=(n_taps, dim))
        out[signal_tap] += centres[spk]
        return out

    # train: 30 speakers x 6 utterances x 3 lengths
    items, rows = [], []
    sel = {}
    for s in range(100, 130):
        sel[str(s)] = []
        for u in range(6):
            utt = f"{s}-1-{u:04d}"
            sel[str(s)].append(utt)
            for length in LENGTHS:
                items.append({"utt": utt, "speaker": str(s), "length": length, "path": ""})
                rows.append(feat(str(s), rng))
    write_feats(root, name, "train", items, {"split": "train", "selection": sel},
                np.stack(rows).transpose(1, 0, 2))
    # dev: 10 speakers, 3 models x 3 utts, 4 test utts
    items, rows, plans, sex = [], [], [], {}
    for i, s in enumerate(range(1, 11)):
        spk = str(s)
        sex[spk] = "F" if i % 2 else "M"
        enroll = [[f"{s}-1-{m * 3 + k:04d}" for k in range(3)] for m in range(3)]
        test = [f"{s}-2-{k:04d}" for k in range(4)]
        plans.append({"speaker": spk, "session": "same_chapter" if i == 0 else "cross_project",
                      "enroll_models": enroll, "test": test})
        for m in enroll:
            for u in m:
                items.append({"utt": u, "speaker": spk, "length": "full", "path": ""})
                rows.append(feat(spk, rng))
        for u in test:
            for length in LENGTHS:
                items.append({"utt": u, "speaker": spk, "length": length, "path": ""})
                rows.append(feat(spk, rng))
    write_feats(root, name, "dev", items, {"split": "dev", "plans": plans, "sex": sex, "subset": {k: "dev-clean" for k in sex}},
                np.stack(rows).transpose(1, 0, 2))


class TestPipeline(unittest.TestCase):
    def test_end_to_end(self):
        rng = np.random.default_rng(0)
        with tempfile.TemporaryDirectory() as tmp:
            feats, out = Path(tmp) / "feats", Path(tmp) / "verify"
            make_world(feats, "base", 3, 1, rng)
            make_world(feats, "m1", 3, 2, np.random.default_rng(1))
            verify.score_system("base", None, 8, False, out / "base", feats)
            verify.score_system("m1", None, 8, False, out / "m1", feats)
            mats, meta = report.load_scores("base", out)
            self.assertEqual(mats["tap1/2s"].shape, (30, 40))
            self.assertEqual(list(meta["model_speaker"][:3]), ["1", "1", "1"])
            report.main(["--systems", "base", "m1", "--workers", "1", "--root", str(out), "--quiet"])
            rep = json.loads((out / "report.json").read_text())
            t = rep["table"]["base"]
            self.assertLess(t["tap1"]["full"]["2s"]["all"]["eer"]["value"], 0.1)
            self.assertGreater(t["tap0"]["full"]["2s"]["all"]["eer"]["value"], 0.2)
            self.assertEqual(rep["best_tap"], {"base": "tap1", "m1": "tap2"})  # chosen on half S
            c = rep["comparisons"]["m1:tap1 - base:tap1"]["E"]["full"]["all"]["eer"]
            self.assertGreater(c["value"], 0.1)
            self.assertEqual(rep["h3"]["verdict"], "different")
            # speaker "1" (same_chapter) contributes no enrollment trials to cross_chapter
            self.assertEqual(t["tap1"]["full"]["full"]["cross_chapter"]["targets"], 9 * 3 * 4)
            # half E has 5 speakers (odd strata F/cross 5 -> E 3, M/same 1 -> S): 5 x 3 models x 4 tests
            self.assertEqual(t["tap1"]["E"]["full"]["all"]["targets"], 5 * 3 * 4)
            self.assertTrue((out / "base" / "backends.npz").exists())


if __name__ == "__main__":
    unittest.main()
