"""W5 identity comparison (sol stepbudget-r1 B5) and the front end's W1 provenance (B2)."""

from __future__ import annotations

import copy
import json
import tempfile
import unittest
from pathlib import Path

import numpy as np

from lfspk.extract import identities


def ident():
    return {"kind": "w5-stage0-render", "seed": 1, "n_per_family": 2,
            "w0": {"w0_code_sha256": "a" * 64, "w0_code_files": ["lfspk/harness/mix.py"], "w0_commit": "c1",
                   "w0_index_hashes": {"librispeech": "l1", "aux": "x1"}},
            "render_code_sha256": "r1"}


class TestComparison(unittest.TestCase):
    def test_docs_only_commit_is_accepted(self):
        a, b = ident(), ident()
        b["w0"]["w0_commit"] = "c2"
        self.assertTrue(identities.same(a, b))
        self.assertEqual(identities.differing(a, b), [])
        self.assertEqual(a["w0"]["w0_commit"], "c1")  # stored records are not rewritten

    def test_code_index_and_other_changes_are_refused(self):
        for path, value in ((("w0", "w0_code_sha256"), "b" * 64), (("w0", "w0_index_hashes"), {"librispeech": "l2", "aux": "x1"}),
                            (("w0", "w0_code_files"), []), (("seed",), 2), (("render_code_sha256",), "r2")):
            b = ident()
            tgt = b
            for k in path[:-1]:
                tgt = tgt[k]
            tgt[path[-1]] = value
            self.assertFalse(identities.same(ident(), b), path)
            self.assertTrue(identities.differing(ident(), b), path)

    def test_only_the_nested_commit_is_excluded(self):
        a, b = ident(), ident()
        a["w0_commit"] = "top"  # a top-level field of that name is compared
        b["w0_commit"] = "other"
        self.assertFalse(identities.same(a, b))
        c = ident()
        del c["w0"]["w0_commit"]  # a missing nested commit compares equal (recorded, not compared)
        self.assertTrue(identities.same(ident(), c))

    def test_all_sites_use_it(self):
        # stage0 render-resume and consumer, calibration consumer, training resume
        from lfspk.extract import stage0

        with tempfile.TemporaryDirectory() as d:
            out = Path(d)
            stored = ident()
            keys = stage0.expected_keys(stored["n_per_family"])
            stage0.prepare_render_dir(out, stored, keys)
            moved = copy.deepcopy(stored)
            moved["w0"]["w0_commit"] = "c9"
            self.assertEqual(stage0.prepare_render_dir(out, moved, keys), keys)  # resume accepted
            self.assertEqual(json.loads((out / "render_identity.json").read_text()), stored)  # not rewritten
            bad = copy.deepcopy(stored)
            bad["w0"]["w0_code_sha256"] = "z" * 64
            with self.assertRaises(RuntimeError):
                stage0.prepare_render_dir(out, bad, keys)
            hashes = {}
            for i, k in enumerate(keys):
                a = np.full(10, i, np.float32)
                np.savez(out / "mix" / f"{k}.npz", audio=a)
                hashes[k] = stage0.audio_sha256(a)
            (out / "render.json").write_text(json.dumps({"identity_sha256": stage0._sha(stored), "keys": hashes}))
            self.assertEqual(stage0.validated_manifest(out, lambda n: moved)["keys"], hashes)
            with self.assertRaises(RuntimeError):
                stage0.validated_manifest(out, lambda n: bad)
        import inspect

        from lfspk.extract import calibrate, train

        self.assertIn("identities", inspect.getsource(calibrate.load_set))
        self.assertIn("identities", inspect.getsource(train.train))


def moved_commit(i, commit="c2"):
    j = copy.deepcopy(i)
    j["w0"]["w0_commit"] = commit
    return j


class TestRenderResume(unittest.TestCase):
    """r2 #1: both render commands, resumed after a docs-only W0 commit, keep the
    manifest bound to the PERSISTED identity, and their consumers accept it."""

    def test_stage0_render_resume(self):
        from unittest import mock

        from lfspk.extract import stage0

        with tempfile.TemporaryDirectory() as d:
            out = Path(d)
            stored = ident()
            stored["n_per_family"] = 1
            keys = stage0.expected_keys(1)
            stage0.prepare_render_dir(out, stored, keys)  # the first render bound the directory
            for i, k in enumerate(keys):  # ... and rendered every key
                a = np.full(320, i, np.float32)
                np.savez(out / "mix" / f"{k}.npz", audio=a, target_image=a, noise=a, labels=np.zeros(2, np.uint8),
                         meta=np.array("{}"), info=np.array("{}"))
            moved = moved_commit(stored)
            with mock.patch.object(stage0, "render_identity", return_value=moved):
                stage0.render(workers=1, n_per=1, out=out)  # resume after a docs-only commit: nothing left to render
            self.assertEqual(json.loads((out / "render_identity.json").read_text()), stored)
            self.assertEqual(json.loads((out / "render.json").read_text())["identity_sha256"], stage0._sha(stored))
            self.assertEqual(sorted(stage0.validated_manifest(out, lambda n: moved)["keys"]), sorted(keys))

    def test_calibration_render_resume_and_consumption(self):
        from unittest import mock

        from lfspk.extract import calibrate, stage0

        old = dict(calibrate.SETS["theta"])
        calibrate.SETS["theta"]["n"] = 2
        self.addCleanup(calibrate.SETS["theta"].update, old)
        info = {"family": "S0", "absent": False, "k": 10, "contamination_rate": 0.0, "contaminated": 0, "matched": 10}
        with tempfile.TemporaryDirectory() as d:
            out = Path(d)
            root = out / "theta"
            stored = ident()
            keys = calibrate.expected_keys("theta")
            stage0.prepare_render_dir(root, stored, keys)
            for i, k in enumerate(keys):
                a = np.full(320, i, np.float32)
                np.savez(root / "mix" / f"{k}.npz", audio=a, target_image=a, noise=a, interfering=np.zeros(2, bool),
                         profile=np.zeros(4, np.float32), info=np.array(json.dumps(info)))
            moved = moved_commit(stored)
            with mock.patch.object(calibrate, "set_identity", return_value=moved):
                calibrate.render("theta", workers=1, out=out)
            self.assertEqual(json.loads((root / "render_identity.json").read_text()), stored)
            got = [k for k, _ in calibrate.load_set("theta", out, lambda n: moved)]
            self.assertEqual(got, keys)
            bad = copy.deepcopy(stored)
            bad["w0"]["w0_index_hashes"] = {"librispeech": "changed"}
            with self.assertRaises(RuntimeError):
                list(calibrate.load_set("theta", out, lambda n: bad))


try:
    from test_W5_data import synthetic_setup  # unittest discover -s tests
except ImportError:
    from tests.test_W5_data import synthetic_setup


class TestTrainResumeIdentity(unittest.TestCase):
    """r2 #2: a resume accepted after a commit-only change keeps the ORIGINAL
    identity in every later write, matching run_meta.json."""

    def test_resume_keeps_persisted_identity(self):
        import torch

        from lfspk.extract import train as T
        from lfspk.extract.data import ExamplePolicy, ExampleSource
        from lfspk.extract.frontend import analytic_mel_power
        from lfspk.extract.harness_frontend import load_checkpoint
        from lfspk.harness.mix import MixtureGenerator
        from lfspk.harness.synthetic import SyntheticCorpus
        from lfspk.pvad.enrollment import EnrollPolicy, target_eligible

        det = torch.are_deterministic_algorithms_enabled()
        self.addCleanup(torch.use_deterministic_algorithms, det)
        with SyntheticCorpus() as corpus, tempfile.TemporaryDirectory() as d:
            parts, bank, _ = synthetic_setup(corpus)
            src = ExampleSource(MixtureGenerator("dev", corpus=corpus), parts, bank,
                                [s for s, p in parts.items() if target_eligible(p)], (),
                                ExamplePolicy(enroll=EnrollPolicy(k_choices=(1,))), _synthetic_test=True)
            cfg = T.TrainConfig(run="R1", seed=1, steps=4, batch=2, crop_frames=120, warmup=2, workers=0, device="cpu",
                                log_every=1, ckpt_every=2, out=str(Path(d) / "r"))
            a = ident()
            T.train(cfg, source=src, ident=a, mel=analytic_mel_power(), stop_after=2)
            b = moved_commit(a)
            final = T.train(cfg, source=src, ident=b, mel=analytic_mel_power())
            run_meta = json.loads((Path(d) / "r" / "run_meta.json").read_text())
            _, meta, _ = load_checkpoint(final)
            self.assertEqual(meta["identity"], a)
            self.assertEqual(meta["identity_sha256"], run_meta["identity_sha256"])
            self.assertEqual(meta["identity_sha256"], T.identity_sha256(a))
            with self.assertRaises(RuntimeError):  # a code change is still refused
                c = copy.deepcopy(a)
                c["w0"]["w0_code_sha256"] = "z" * 64
                cfg2 = T.TrainConfig(**{**cfg.__dict__, "out": str(Path(d) / "s")})
                T.train(cfg2, source=src, ident=a, mel=analytic_mel_power(), stop_after=2)
                T.train(cfg2, source=src, ident=c, mel=analytic_mel_power())


class TestFrontEndProvenance(unittest.TestCase):
    def test_w1_artifact_hashes(self):
        from lfspk.extract import harness_frontend as hf

        with tempfile.TemporaryDirectory() as d:
            root = Path(d)
            args = ("redimnet2-b2", "raw", "robust", "score", "1.5", "0.25", "1.0")
            p = hf.w1_artifact_paths(*args, root=root)
            self.assertEqual(set(p), {"head", "head_sidecar", "gates"})
            self.assertEqual(set(hf.w1_artifact_paths("redimnet2-b2", "asnorm", "naive", "score", "1.5", "0.25", "1.0",
                                                      root=root)), {"head", "head_sidecar", "cohort_full", "cohort_seg",
                                                                    "cohort_seg_tsv"})
            for f in p.values():
                f.parent.mkdir(parents=True, exist_ok=True)
                f.write_text("x")
            h1 = hf.w1_artifact_sha256s(*args, root=root)
            p["gates"].write_text("y")
            h2 = hf.w1_artifact_sha256s(*args, root=root)
            self.assertNotEqual(h1["gates"], h2["gates"])
            self.assertEqual(h1["head"], h2["head"])
        self.assertEqual(len(hf.w1_code_sha256()), 64)

    def test_make_identity_carries_w1_provenance(self):
        # r2 #3: through make(...).identity(); replacing an artefact at the same path changes it
        from unittest import mock

        from lfspk.api import CostReport
        from lfspk.extract import harness_frontend as hf
        from lfspk.extract.model import MaskNet, config_for

        class Stub:
            name = "stub"

            def cost(self):
                return CostReport(params=1, macs_per_audio_second=0.0, update_macs=0.0, profile_bytes=0)

        with tempfile.TemporaryDirectory() as d:
            d = Path(d)
            ck = d / "final.pt"
            hf.save_checkpoint(ck, MaskNet(config_for("S")), {"embedder": "redimnet2-b2", "run": "R1", "seed": 0})
            root = d / "W1"
            for p in hf.w1_artifact_paths("redimnet2-b2", "raw", "robust", "score", "1.5", "0.25", "1.0", root=root).values():
                p.parent.mkdir(parents=True, exist_ok=True)
                p.write_text("v1")
            calls = []
            with mock.patch("lfspk.embed.factory.make", side_effect=lambda **kw: calls.append(kw) or Stub()):
                i1 = hf.make(str(ck), runs=str(root)).identity()
                self.assertEqual(calls[-1]["runs"], str(root))  # the profile path reads the same root
                (root / "adapt" / "train" / "redimnet2-b2" / "gates_raw.json").write_text("v2")  # same path, new content
                i2 = hf.make(str(ck), runs=str(root)).identity()
        self.assertEqual(set(i1["profiler"]["w1_artifact_sha256"]), {"head", "head_sidecar", "gates"})
        self.assertEqual(len(i1["profiler"]["w1_code_sha256"]), 64)
        self.assertNotEqual(i1["profiler"]["w1_artifact_sha256"]["gates"], i2["profiler"]["w1_artifact_sha256"]["gates"])
        self.assertNotEqual(json.dumps(i1, sort_keys=True), json.dumps(i2, sort_keys=True))

    def test_implicit_and_explicit_default_root_give_equal_identity(self):
        # sol stepbudget-r3: make(ck) and make(ck, runs=<RUNS/W1>) read the same files, so equal identity
        from unittest import mock

        from lfspk import paths
        from lfspk.api import CostReport
        from lfspk.extract import harness_frontend as hf
        from lfspk.extract.model import MaskNet, config_for

        class Stub:
            name = "stub"

            def cost(self):
                return CostReport(params=1, macs_per_audio_second=0.0, update_macs=0.0, profile_bytes=0)

        with tempfile.TemporaryDirectory() as d:
            ck = Path(d) / "final.pt"
            hf.save_checkpoint(ck, MaskNet(config_for("S")), {"embedder": "redimnet2-b2", "run": "R1", "seed": 0})
            calls = []
            with mock.patch("lfspk.embed.factory.make", side_effect=lambda **kw: calls.append(kw) or Stub()):
                implicit = hf.make(str(ck)).identity()
                explicit = hf.make(str(ck), runs=str(paths.RUNS / "W1")).identity()
        self.assertEqual(json.dumps(implicit, sort_keys=True), json.dumps(explicit, sort_keys=True))
        self.assertEqual(calls[0]["runs"], calls[1]["runs"])
        self.assertEqual(implicit["profiler"]["w1_runs_root"], str((paths.RUNS / "W1").resolve()))


if __name__ == "__main__":
    unittest.main()
