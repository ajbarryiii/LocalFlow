"""W5 training loop (DESIGN section 8) on W0's synthetic corpus, CPU only."""

from __future__ import annotations

import json
import tempfile
import unittest
from pathlib import Path

import numpy as np
import torch

from lfspk.extract import train as T
from lfspk.extract.frontend import analytic_mel_power
from lfspk.harness.synthetic import SyntheticCorpus
from lfspk.pvad.enrollment import EnrollPolicy, target_eligible

try:
    from test_W5_data import synthetic_setup  # unittest discover -s tests
except ImportError:
    from tests.test_W5_data import synthetic_setup  # python -m unittest tests.test_W5_train


class TestSchedule(unittest.TestCase):
    def test_lr(self):
        cfg = T.TrainConfig(run="R1", seed=0, steps=3000, warmup=1000)
        self.assertAlmostEqual(T.lr_at(0, cfg), 2e-3 / 1000)
        self.assertAlmostEqual(T.lr_at(999, cfg), 2e-3)
        self.assertAlmostEqual(T.lr_at(2000, cfg), 1e-3, places=9)
        self.assertLess(T.lr_at(2999, cfg), 1e-8)

    def test_config(self):
        with self.assertRaises(ValueError):
            T.TrainConfig(run="R9", seed=0, steps=10)
        self.assertEqual(T.RUNS["R2"]["conditioning"], "none")
        self.assertEqual(T.RUNS["R3"]["target_kind"], "T1")


class TestTrainLoop(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        from lfspk.extract.data import ExamplePolicy, ExampleSource
        from lfspk.harness.mix import MixtureGenerator

        cls._ctx = SyntheticCorpus()
        corpus = cls._ctx.__enter__()
        parts, bank, _ = synthetic_setup(corpus)
        targets = [s for s, p in parts.items() if target_eligible(p)]
        gen = MixtureGenerator("dev", corpus=corpus)
        pol = ExamplePolicy(enroll=EnrollPolicy(k_choices=(1, 2)))
        cls.src = ExampleSource(gen, parts, bank, targets, (), pol, _synthetic_test=True)
        cls.det = torch.are_deterministic_algorithms_enabled()

    @classmethod
    def tearDownClass(cls):
        cls._ctx.__exit__(None, None, None)
        torch.use_deterministic_algorithms(cls.det)

    def cfg(self, steps, out):
        return T.TrainConfig(run="R1", seed=3, steps=steps, batch=2, crop_frames=120, warmup=2, workers=0, device="cpu",
                             log_every=1, ckpt_every=2, out=str(out))

    def run_train(self, steps, out, ident=None, stop_after=None):
        return T.train(self.cfg(steps, out), source=self.src, ident=ident or {"test": 1}, mel=analytic_mel_power(),
                       stop_after=stop_after)

    def test_resume_is_bit_identical(self):
        from lfspk.extract.harness_frontend import load_checkpoint

        with tempfile.TemporaryDirectory() as d:
            d = Path(d)
            full = self.run_train(4, d / "full")
            self.assertIsNone(self.run_train(4, d / "cut", stop_after=2))  # interrupted after the step-2 checkpoint
            self.assertEqual(torch.load(d / "cut" / "last.pt", weights_only=False)["step"], 2)
            resumed = self.run_train(4, d / "cut")
            a, _, _ = load_checkpoint(full)
            b, _, _ = load_checkpoint(resumed)
            for k, v in a.state_dict().items():
                self.assertTrue(torch.equal(v, b.state_dict()[k]), k)

    def test_finished_and_orphaned_runs_are_refused(self):
        with tempfile.TemporaryDirectory() as d:
            d = Path(d)
            self.run_train(2, d / "a")
            with self.assertRaises(FileExistsError):
                self.run_train(2, d / "a")
            (d / "b").mkdir()
            (d / "b" / "log.jsonl").write_text("{}\n")
            with self.assertRaises(RuntimeError):
                self.run_train(2, d / "b")

    def test_resume_refuses_other_identity(self):
        with tempfile.TemporaryDirectory() as d:
            d = Path(d)
            self.run_train(4, d / "a", stop_after=2)
            with self.assertRaises(RuntimeError):
                self.run_train(4, d / "a", ident={"test": 2})

    def test_log_and_checkpoint_meta(self):
        with tempfile.TemporaryDirectory() as d:
            out = self.run_train(2, Path(d) / "a")
            log = [json.loads(l) for l in (Path(d) / "a" / "log.jsonl").read_text().splitlines()]
            self.assertEqual([r["step"] for r in log], [1, 2])
            self.assertTrue(all(np.isfinite(r["loss"]) for r in log))
            from lfspk.extract.harness_frontend import load_checkpoint

            _, meta, _ = load_checkpoint(out)
            self.assertEqual(meta["steps"], 2)
            self.assertEqual(meta["run"], "R1")

    def test_source_must_match_run(self):
        cfg = T.TrainConfig(run="R2", seed=0, steps=2, batch=1, workers=0, device="cpu")
        with self.assertRaises(ValueError):  # R2 needs an unconditioned source
            T.Stream(cfg, 0, self.src)
        with self.assertRaises(ValueError):
            T.Stream(T.TrainConfig(run="R1", seed=0, steps=2, batch=1, workers=2, device="cpu"), 0, self.src)


class TestTrainIdentityAndStream(unittest.TestCase):
    def test_json_safe_identity_loads_with_weights_only(self):
        # implT-r1 #1: torch.__version__ is a TorchVersion; it must not reach the checkpoint
        ident = T.json_safe({"torch": torch.__version__, "numpy": np.__version__})
        self.assertIs(type(ident["torch"]), str)
        from lfspk.extract.harness_frontend import load_checkpoint, save_checkpoint
        from lfspk.extract.model import MaskNet, config_for

        with tempfile.TemporaryDirectory() as d:
            p = Path(d) / "c.pt"
            save_checkpoint(p, MaskNet(config_for("S")), T.json_safe({"identity": {"torch": torch.__version__}}))
            _, meta, _ = load_checkpoint(p)
            self.assertEqual(meta["identity"]["torch"], str(torch.__version__))
            with self.assertRaises(Exception):  # the unsafe form is what broke production loads
                save_checkpoint(p, MaskNet(config_for("S")), {"identity": {"torch": torch.__version__}})
                load_checkpoint(p)

    def test_w3_code_hash(self):
        # implT-r2: every transitively imported W3 module, found in a fresh interpreter
        self.assertEqual(len(T.w3_code_sha256()), 64)
        mods = T.w3_modules()
        for m in ("pvad/enrollment.py", "pvad/w0_source.py", "pvad/features.py", "pvad/bank_build.py"):
            self.assertIn(m, mods)

    def test_render_code_change_invalidates_reuse(self):
        # implT-r2 #2: the calibration render identity covers calibrate.py, and any byte change shows
        from lfspk.extract import calibrate

        self.assertIn("calibrate.py", calibrate.RENDER_FILES)
        with tempfile.TemporaryDirectory() as d:
            d = Path(d)
            (d / "a.py").write_text("x = 1\n")
            (d / "b.py").write_text("y = 2\n")
            h1 = T.files_sha256([d / "a.py", d / "b.py"], d)
            self.assertEqual(h1, T.files_sha256([d / "b.py", d / "a.py"], d))
            (d / "b.py").write_text("y = 3\n")
            self.assertNotEqual(h1, T.files_sha256([d / "a.py", d / "b.py"], d))

    def test_stream_backpressure_and_order(self):
        # implT-r1 #2: at most `prefetch` batches in flight, order kept
        class Res:
            def __init__(self, v):
                self.v = v

            def get(self):
                return self.v

        class FakePool:
            def __init__(self):
                self.submitted = 0

            def apply_async(self, fn, args):
                self.submitted += 1
                return Res(args[0][1])

            def terminate(self):
                pass

        cfg = T.TrainConfig(run="R1", seed=0, steps=10, batch=4, workers=0, device="cpu")

        class Src:
            conditioned = True

            class policy:
                target_kind = "T2"
                p_absent = 0.05  # the stream now also checks the source's absent-target probability

        st = T.Stream(cfg, 0, Src(), prefetch=2)
        st.pool, st.ks = FakePool(), iter(range(40))
        st._fill()
        self.assertEqual(len(st.pending), 8)
        self.assertEqual(st.batch(), [0, 1, 2, 3])
        self.assertEqual(len(st.pending), 8)  # refilled, never beyond the cap
        self.assertEqual(st.pool.submitted, 12)
        self.assertEqual(st.batch(), [4, 5, 6, 7])


class TestTheta(unittest.TestCase):
    def test_theta_population_check(self):
        from lfspk.extract import calibrate

        ok = {"family": "S0", "absent": False, "k": 10, "contamination_rate": 0.0, "contaminated": 0, "matched": 10}
        calibrate.check_theta_conditions(ok)
        for bad in ({**ok, "k": 3}, {**ok, "contaminated": 1}, {**ok, "absent": True}, {**ok, "family": "S4"},
                    {**ok, "matched": 9}):
            with self.assertRaises(RuntimeError):
                calibrate.check_theta_conditions(bad)

    def test_load_set_validates(self):
        # implT-r1 #4: exact keys, audio hashes and recorded conditions
        from lfspk.extract import calibrate, stage0

        old = dict(calibrate.SETS["theta"])
        calibrate.SETS["theta"]["n"] = 2
        self.addCleanup(calibrate.SETS["theta"].update, old)
        with tempfile.TemporaryDirectory() as d:
            out = Path(d)
            root = out / "theta"
            keys = calibrate.expected_keys("theta")
            ident = {"id": 1}
            stage0.prepare_render_dir(root, ident, keys)
            hashes, conds = {}, {}
            for i, k in enumerate(keys):
                a = np.full(320, i, np.float32)
                info = {"family": "S0", "absent": False, "k": 10, "contamination_rate": 0.0, "contaminated": 0,
                        "matched": 10}
                np.savez(root / "mix" / f"{k}.npz", audio=a, target_image=a, noise=a, interfering=np.zeros(2, bool),
                         profile=np.zeros(4, np.float32), info=np.array(json.dumps(info)))
                hashes[k], conds[k] = stage0.audio_sha256(a), info
            man = {"identity_sha256": stage0._sha(ident), "keys": hashes, "conditions": conds}
            (root / "render.json").write_text(json.dumps(man))
            same = lambda name: {"id": 1}  # noqa: E731  (the current identity, injected)
            self.assertEqual([k for k, _ in calibrate.load_set("theta", out, same)], keys)
            with self.assertRaises(RuntimeError):  # implI2-r2 #3: the current identity differs from the stored one
                list(calibrate.load_set("theta", out, lambda name: {"id": 2}))
            (root / "render.json").write_text(json.dumps({**man, "conditions": {**conds, keys[0]: {**conds[keys[0]], "k": 3}}}))
            with self.assertRaises(RuntimeError):
                list(calibrate.load_set("theta", out, same))
            (root / "render.json").write_text(json.dumps({**man, "keys": {**hashes, keys[1]: "0" * 64}}))
            with self.assertRaises(RuntimeError):
                list(calibrate.load_set("theta", out, same))
            (root / "render.json").write_text(json.dumps(man))
            np.savez(root / "mix" / "S0-009.npz", audio=np.zeros(3, np.float32))
            with self.assertRaises(RuntimeError):
                list(calibrate.load_set("theta", out, same))

    def test_quantile_rule(self):
        mx = np.linspace(0, 1, 500)
        th = float(np.quantile(mx, 0.99, method="higher"))
        self.assertIn(th, mx)
        self.assertLessEqual(float(np.mean(mx >= th)), 0.011)


if __name__ == "__main__":
    unittest.main()
