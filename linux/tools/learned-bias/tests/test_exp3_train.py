"""Contract tests for experiment 3's training flags (DESIGN-3
"Implementation contracts", P): --lr, --horizon-steps, --checkpoint-steps,
--train-seed, --calls-file, --fixed-lambda; and stop/resume determinism."""

import contextlib
import hashlib
import io
import json
import math
import os
import tempfile
import unittest
from pathlib import Path
from unittest import mock

import torch

# Importable both as `tests.<module>` (-t) and as a top-level module (-s only).
_ROOT = str(__import__("pathlib").Path(__file__).resolve().parents[1])  # linux/tools/learned-bias
if _ROOT not in __import__("sys").path:
    __import__("sys").path.insert(0, _ROOT)

from learned_bias import train
from learned_bias.fixtures import synthetic_export, synthetic_shard
from learned_bias.joint import JointOutput

from tests.helpers import TRAIN_DF, fake_eval, make_prep


def run_train(args):
    with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
        return train.main(args)


def sha(p):
    return hashlib.sha256(Path(p).read_bytes()).hexdigest()


def content(p):
    """Tensor and metadata content of a model file (its bytes vary: the
    header's metadata order is a Rust HashMap's)."""
    from tests.golden_exp2 import content_sha256

    return content_sha256(p)


class Toy(unittest.TestCase):
    """Synthetic CPU runs: 3 shards (about 8 batches each at --batch 4)."""

    @classmethod
    def setUpClass(cls):
        cls._tmp = tempfile.TemporaryDirectory()
        d = cls.d = Path(cls._tmp.name)
        cls.export = synthetic_export(d / "export")
        jo = JointOutput.from_export(cls.export)
        for i in range(3):
            synthetic_shard(d / "prep" / "train" / f"c{i}.0.safetensors", seed=70 + i, utterances=5,
                            session=f"c{i}", joint=jo, dataset=("spgispeech", "icsi", "icsi")[i])
        cls.n = 0

    @classmethod
    def tearDownClass(cls):
        cls._tmp.cleanup()

    def toy(self, *extra, variant="L2"):
        type(self).n += 1
        name = f"r{type(self).n}"
        rc = run_train(["--variant", variant, "--run", name, "--prep", str(self.d / "prep"),
                        "--out-root", str(self.d / "train"), "--export", str(self.export), "--device", "cpu",
                        "--toy", "--batch", "4", "--log-every", "1", *extra])
        self.assertEqual(rc, 0)
        return self.d / "train" / name

    @staticmethod
    def info(run):
        return json.loads((run / "run.json").read_text())

    @staticmethod
    def metrics(run):
        return [json.loads(x) for x in (run / "metrics.jsonl").read_text().splitlines()]


class StepPlanTests(Toy):
    def test_checkpoints_at_the_listed_steps_only(self):
        run = self.toy("--horizon-steps", "60", "--checkpoint-steps", "10,30,45")
        info = self.info(run)
        self.assertEqual(info["checkpoints"], ["s10", "s30", "s45"])
        self.assertEqual(info["checkpoints_planned"], ["s10", "s30", "s45"])
        self.assertEqual(info["step_plan"], [10, 30, 45])
        self.assertEqual((info["horizon_steps"], info["lr"], info["train_seed"]), (60, 1e-3, 20261011))
        self.assertEqual(sorted(p.name for p in run.glob("model-*.safetensors")),
                         ["model-s10.safetensors", "model-s30.safetensors", "model-s45.safetensors"])
        steps = [r["step"] for r in self.metrics(run) if "loss" in r]
        self.assertEqual(steps[-1], 45)  # stops after the last checkpoint, across epochs
        self.assertGreater(45, info["steps_per_epoch"])

    def test_cosine_horizon_is_independent_of_the_stop(self):
        run = self.toy("--lr", "2e-3", "--horizon-steps", "40", "--checkpoint-steps", "20")
        lrs = {r["step"]: r["lr"] for r in self.metrics(run) if "loss" in r}
        for s in (1, 10, 20):
            self.assertAlmostEqual(lrs[s], 2e-3 * 0.5 * (1 + math.cos(math.pi * s / 40)), places=12)

    def test_stop_at_s_reproduces_the_longer_run_bit_exactly(self):
        # DESIGN-3 "Seed replicates": stopping at S with horizon H reproduces
        # the longer run's checkpoint at S (CPU: bit-exact).
        long = self.toy("--horizon-steps", "60", "--checkpoint-steps", "10,30,45")
        short = self.toy("--horizon-steps", "60", "--checkpoint-steps", "30")
        self.assertEqual(content(long / "model-s30.safetensors"), content(short / "model-s30.safetensors"))
        a, b = (torch.load(r / "ckpt-s30.pt", weights_only=False) for r in (long, short))
        self.assertEqual(a["step"], b["step"])
        for k, v in a["model"].items():
            self.assertTrue(torch.equal(v, b["model"][k]), k)
        for (ka, sa), (kb, sb) in zip(a["opt"]["state"].items(), b["opt"]["state"].items()):
            for name in sa:
                self.assertTrue(torch.equal(torch.as_tensor(sa[name]), torch.as_tensor(sb[name])), name)
        # The same at another seed (as the replicates use).
        l2 = self.toy("--horizon-steps", "60", "--checkpoint-steps", "10,30", "--train-seed", "20261012")
        s2 = self.toy("--horizon-steps", "60", "--checkpoint-steps", "10", "--train-seed", "20261012")
        self.assertEqual(content(l2 / "model-s10.safetensors"), content(s2 / "model-s10.safetensors"))
        self.assertNotEqual(content(l2 / "model-s10.safetensors"), content(long / "model-s10.safetensors"))

    def test_replicate_run_json_differs_only_in_allow_listed_fields(self):
        # A real selected run and its replicate, as train.py writes them,
        # pass analysis3's configuration comparison; another batch does not.
        from learned_bias.analysis3 import config_problems

        sel = self.toy("--horizon-steps", "60", "--checkpoint-steps", "10,30")
        rep = self.toy("--horizon-steps", "60", "--checkpoint-steps", "30", "--train-seed", "20261012",
                       "--fixed-lambda", "1")
        ident = self.info(sel)["identity"]
        self.assertEqual(set(ident), {"prep_index_sha256", "policy_sha256", "shard_pool_sha256",
                                      "export_weights_sha256", "dev_cmd_sha256"})
        self.assertEqual(ident, self.info(rep)["identity"])
        self.assertEqual(config_problems("rep", self.info(rep), self.info(sel), 1.0), [])
        other = self.toy("--horizon-steps", "60", "--checkpoint-steps", "30", "--train-seed", "20261012",
                         "--batch", "8")
        self.assertTrue(config_problems("other", self.info(other), self.info(sel), 1.0))

    def test_seen_counts_per_dataset_are_cumulative(self):
        run = self.toy("--horizon-steps", "60", "--checkpoint-steps", "10,30,45")
        stats = self.info(run)["checkpoint_stats"]
        self.assertEqual(list(stats), ["s10", "s30", "s45"])
        prev = None
        for tag in ("s10", "s30", "s45"):
            seen = stats[tag]["seen"]
            self.assertEqual(set(seen), {"spgispeech", "icsi"})
            total = sum(v["decisions"] for v in seen.values())
            self.assertLessEqual(total, 4 * stats[tag]["step"])  # at most --batch per step
            self.assertGreaterEqual(total, stats[tag]["step"])
            for ds, v in seen.items():
                self.assertLessEqual(v["corrections"], v["decisions"])
                self.assertLessEqual(v["calls"], {"spgispeech": 1, "icsi": 2}[ds])
                if prev:
                    for k in ("calls", "decisions", "corrections"):
                        self.assertGreaterEqual(v[k], prev[ds][k])
            prev = seen
        # After more than one epoch every call has been seen.
        self.assertEqual({ds: v["calls"] for ds, v in stats["s45"]["seen"].items()}, {"spgispeech": 1, "icsi": 2})
        recs = [r for r in self.metrics(run) if "checkpoint" in r]
        self.assertEqual([r["seen"] for r in recs], [stats[t]["seen"] for t in ("s10", "s30", "s45")])

    def test_flag_validation(self):
        base = ["--variant", "L2", "--run", "bad", "--prep", str(self.d / "prep"), "--out-root",
                str(self.d / "train"), "--export", str(self.export), "--device", "cpu", "--toy"]
        bad = [
            ["--checkpoint-steps", "10,20"],  # needs --horizon-steps
            ["--checkpoint-steps", "20,10", "--horizon-steps", "40"],
            ["--checkpoint-steps", "0,10", "--horizon-steps", "40"],
            ["--checkpoint-steps", "10,10", "--horizon-steps", "40"],
            ["--checkpoint-steps", "x", "--horizon-steps", "40"],
            ["--checkpoint-steps", "10", "--horizon-steps", "40", "--epochs", "2"],
            ["--checkpoint-steps", "10", "--horizon-steps", "40", "--max-steps", "5"],
            ["--horizon-steps", "0"],
            ["--fixed-lambda", "0.8"],
        ]
        for extra in bad:
            with self.assertRaises(SystemExit, msg=extra), contextlib.redirect_stderr(io.StringIO()):
                train.main(base + extra)


class SeedAndSubsetTests(Toy):
    def test_train_seed_is_separate_from_the_frozen_seed(self):
        plan = ["--horizon-steps", "40", "--checkpoint-steps", "8"]
        a = self.toy(*plan)
        b = self.toy(*plan, "--train-seed", "20261011")
        c = self.toy(*plan, "--train-seed", "5")
        self.assertEqual(content(a / "model-s8.safetensors"), content(b / "model-s8.safetensors"))
        self.assertNotEqual(content(a / "model-s8.safetensors"), content(c / "model-s8.safetensors"))
        # The subset (frozen seed) does not move with the training seed.
        d = self.toy(*plan, "--call-fraction", "0.5", "--train-seed", "1")
        e = self.toy(*plan, "--call-fraction", "0.5", "--train-seed", "2")
        self.assertEqual((d / "calls.txt").read_text(), (e / "calls.txt").read_text())
        self.assertEqual(self.info(c)["train_seed"], 5)

    def test_calls_file_is_used_exactly(self):
        f = self.d / "subset.txt"
        f.write_text("icsi/c2\nspgispeech/c0\n")
        run = self.toy("--horizon-steps", "40", "--checkpoint-steps", "8", "--calls-file", str(f))
        self.assertEqual((run / "calls.txt").read_text(), "icsi/c2\nspgispeech/c0\n")
        info = self.info(run)
        self.assertEqual(info["calls_file"], {"path": str(f.resolve()), "sha256": sha(f), "calls": 2})
        self.assertEqual(info["shards"], 2)
        bad = {
            "unknown": "icsi/c2\nicsi/c9\n",
            "empty": "\n",
            "duplicate": "icsi/c2\nicsi/c2\n",
        }
        for name, text in bad.items():
            f.write_text(text)
            with self.assertRaises(SystemExit, msg=name), contextlib.redirect_stderr(io.StringIO()):
                self.toy("--horizon-steps", "40", "--checkpoint-steps", "8", "--calls-file", str(f))
        f.write_text("icsi/c2\n")
        with self.assertRaises(SystemExit), contextlib.redirect_stderr(io.StringIO()):
            self.toy("--calls-file", str(f), "--call-fraction", "0.5")


class Experiment2UnchangedTests(Toy):
    """With none of the new flags, experiment 2's behaviour is unchanged:
    half-epoch checkpoints named e*, and run.json without the new keys."""

    def test_no_new_flags_keeps_experiment_2_layout(self):
        run = self.toy("--epochs", "2")
        info = self.info(run)
        self.assertTrue(all(t.startswith("e") for t in info["checkpoints"]))
        for k in ("step_plan", "horizon_steps", "train_seed", "calls_file", "checkpoint_stats", "lr"):
            self.assertNotIn(k, info)
        for k in ("horizon_steps", "checkpoint_steps", "train_seed", "calls_file", "fixed_lambda"):
            self.assertNotIn(k, info["args"])
        self.assertEqual(info["args"]["epochs"], "2.0")
        self.assertFalse(any("seen" in r for r in self.metrics(run)))


GPU_TOLERANCE = 1e-5  # max |Δw| / (1 + |w|) on CUDA (measured: exactly 0)


class GpuDeterminismTests(unittest.TestCase):
    """Opt-in (LF_GPU_TEST=1 and LF_GPU_LOCK; takes the GPU lock): the
    stop/resume contract on CUDA with deterministic algorithms, within
    GPU_TOLERANCE. Measured on the RTX 5090 (300 steps, L2 and L3): exact."""

    def test_stop_at_s_on_the_gpu(self):
        if os.environ.get("LF_GPU_TEST") != "1" or not os.environ.get("LF_GPU_LOCK"):
            self.skipTest("set LF_GPU_TEST=1 and LF_GPU_LOCK to run on the GPU")
        from safetensors.torch import load_file

        with tempfile.TemporaryDirectory() as d:
            d = Path(d)
            export = synthetic_export(d / "export")
            jo = JointOutput.from_export(export)
            for i in range(3):
                synthetic_shard(d / "prep" / "train" / f"c{i}.0.safetensors", seed=300 + i, utterances=8,
                                session=f"c{i}", joint=jo)
            for name, plan in (("long", "50,100"), ("short", "50")):
                self.assertEqual(run_train(["--variant", "L2", "--run", name, "--prep", str(d / "prep"),
                                            "--out-root", str(d / "train"), "--export", str(export),
                                            "--device", "cuda", "--toy", "--batch", "8",
                                            "--horizon-steps", "200", "--checkpoint-steps", plan]), 0)
            a = load_file(str(d / "train" / "long" / "model-s50.safetensors"))
            b = load_file(str(d / "train" / "short" / "model-s50.safetensors"))
            for k in a:
                rel = ((a[k].double() - b[k].double()).abs() / (1 + b[k].double().abs())).max()
                self.assertLessEqual(float(rel), GPU_TOLERANCE, k)


class GoldenTests(unittest.TestCase):
    """Byte-identity with experiment 2: tests/golden_exp2.json holds the
    output hashes of the experiment-2 code (commit 9cd286c) on a fixed toy
    (tests/golden_exp2.py; CPU, one thread). The new code, without the new
    flags, must reproduce them exactly."""

    def test_experiment_2_outputs_are_byte_identical(self):
        from tests.golden_exp2 import GOLDEN_TORCH, run_golden

        if torch.__version__ != GOLDEN_TORCH:
            self.skipTest(f"golden hashes were made with torch {GOLDEN_TORCH}")
        golden = json.loads(Path(__file__).with_name("golden_exp2.json").read_text())
        self.assertEqual(run_golden(), golden)


class ExperimentModeTests(unittest.TestCase):
    """Non-toy: every step checkpoint is dev-checked with the mandatory
    command; the model id is VARIANT/RUN/model-s{step}; replicate mode."""

    def test_step_checkpoints_are_dev_checked(self):
        with tempfile.TemporaryDirectory() as d, mock.patch.dict(os.environ, {"FAKE_EVAL_DF": TRAIN_DF}):
            d = Path(d)
            export, prep, _ = make_prep(d, sessions=1, joint=True)
            cmd, res = fake_eval(d)
            base = ["--variant", "L2", "--prep", str(prep), "--out-root", str(d / "train"), "--export", str(export),
                    "--device", "cpu", "--batch", "16", "--horizon-steps", "20", "--dev-check-cmd", cmd,
                    "--dev-check-results", res]
            self.assertEqual(run_train(base + ["--run", "A1", "--checkpoint-steps", "3,6"]), 0)
            run = d / "train" / "A1"
            db = json.loads((run / "devcheck.json").read_text())
            self.assertEqual(set(db), {"s3", "s6"})
            self.assertEqual(db["s6"]["model_id"], "L2/A1/model-s6")
            sel = json.loads((run / "selection.json").read_text())
            self.assertEqual(sel["selected"]["checkpoint"], "s3")  # equal objectives: fewer steps
            # Replicate mode: the frozen λ's objective, marked fixed.
            self.assertEqual(run_train(base + ["--run", "R1", "--checkpoint-steps", "6", "--train-seed", "20261012",
                                               "--fixed-lambda", "1"]), 0)
            rep = json.loads((d / "train" / "R1" / "selection.json").read_text())
            self.assertEqual(rep["mode"], "fixed_lambda")
            self.assertTrue(rep["fixed"])
            self.assertEqual(rep["lambda"], 1.0)
            self.assertEqual(rep["objectives"], {"s6": 0.97})
            self.assertNotIn("selected", rep)


if __name__ == "__main__":
    unittest.main()
