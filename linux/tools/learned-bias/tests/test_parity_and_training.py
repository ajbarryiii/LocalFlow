import contextlib
import io
import json
import os
import tempfile
import unittest
from pathlib import Path
from unittest import mock

import numpy as np
import torch
from safetensors import safe_open

# Importable both as `tests.<module>` (-t) and as a top-level module (-s only).
_ROOT = str(__import__("pathlib").Path(__file__).resolve().parents[1])  # linux/tools/learned-bias
if _ROOT not in __import__("sys").path:
    __import__("sys").path.insert(0, _ROOT)

from learned_bias import V
from learned_bias.features import candidate_features
from learned_bias.fixtures import parity_case, synthetic_export, synthetic_shard, write_parity
from learned_bias.joint import JointOutput
from learned_bias.model import BiasModel, Trie, check_tensors, load_model
from learned_bias.trie import BiasTrie

from tests.helpers import SPGI_TRAIN, TRAIN_DF, fake_eval, make_prep


class ParityFixtureTests(unittest.TestCase):
    """The fixture's own consistency; R1's Rust test checks the Rust side."""

    def test_fixture_is_self_consistent(self):
        with tempfile.TemporaryDirectory() as d:
            paths = write_parity(d)
            self.assertEqual([p.name for p in paths],
                             [f"parity-{v}.safetensors" for v in ("L1", "L2", "L3", "L3S")])
            for p in paths:
                with safe_open(str(p), framework="pt") as f:
                    meta = f.metadata()
                    t = {k: f.get_tensor(k) for k in f.keys()}
                v = meta["variant"]
                model_t = {k: x for k, x in t.items() if not k.startswith("fx.")}
                check_tensors(v, model_t)
                fx = {k[3:]: x for k, x in t.items() if k.startswith("fx.")}
                for k, x in fx.items():
                    self.assertIn(x.dtype, (torch.int32, torch.float32), k)
                # Weights are random: b != 0, final layer not zero.
                final = "l1.2.weight" if v == "L1" else "sc.2.weight"
                self.assertGreater(float(model_t[final].abs().max()), 0)
                if v in ("L3", "L3S"):
                    self.assertNotEqual(float(model_t["gate"][0]), 0.0)
                # Candidates are BiasGraph::candidates of the phrases' graph.
                off = fx["phrase.offset"].tolist()
                toks = fx["phrase.tokens"].tolist()
                bt = BiasTrie([toks[a:b] for a, b in zip(off, off[1:])])
                co = fx["cand.offset"].tolist()
                for i, s in enumerate(fx["dec.state"].tolist()):
                    got = list(zip(fx["cand.token"][co[i]:co[i + 1]].tolist(),
                                   fx["cand.dest"][co[i]:co[i + 1]].tolist()))
                    self.assertEqual(got, bt.candidates(s))
                # The f32 model reproduces expected_bonus within the Rust tolerance.
                m = BiasModel(v)
                m.load_state_dict(model_t)
                trie = Trie.build(fx["trie.token"], fx["trie.depth"], fx["trie.parent"], fx["trie.nf"])
                dec = torch.repeat_interleave(torch.arange(len(co) - 1), torch.tensor(np.diff(co)))
                ct, cdst = fx["cand.token"].long(), fx["cand.dest"].long()
                x = candidate_features(trie.nf, fx["dec.logits"], dec, ct, cdst, float(fx["g_size"][0]))
                torch.testing.assert_close(x, fx["cand.x"], rtol=1e-6, atol=1e-6)
                with torch.no_grad():
                    b = m.bonus(m.node_pass(trie), fx["dec.z"], x, dec, cdst)
                eb = fx["expected_bonus"]
                self.assertTrue(torch.all((b - eb).abs() <= 1e-4 * (1 + eb.abs())), v)
                self.assertGreater(float(eb.abs().max()), 1.0)
                self.assertGreater(float(meta["min_top2_gap"]), 1e-3)
                # The bonus changes the argmax somewhere.
                base = fx["dec.logits"][:, :V].argmax(1)
                self.assertTrue(bool((base != fx["expected_argmax"].long()).any()), v)

    def test_written_fixture_matches_fresh_case(self):
        # Deterministic: regenerating gives identical tensors.
        a, _ = parity_case("L2", seed=99, decisions=8)
        b, _ = parity_case("L2", seed=99, decisions=8)
        self.assertEqual(set(a), set(b))
        for k in a:
            np.testing.assert_array_equal(a[k], b[k])


def run_train(args):
    from learned_bias import train

    with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
        return train.main(args)


class ToyTrainingTests(unittest.TestCase):
    def test_loss_decreases_and_checkpoints_export(self):
        with tempfile.TemporaryDirectory() as d:
            d = Path(d)
            exp = synthetic_export(d / "export")
            jo = JointOutput.from_export(exp / "export.safetensors")
            for i in range(4):
                synthetic_shard(d / "prep" / "train" / f"call{i}.0.safetensors", seed=10 + i,
                                utterances=6, session=f"call{i}", joint=jo)
            for v in ("L1", "L3"):
                rc = run_train([
                    "--variant", v, "--run", f"toy-{v}", "--prep", str(d / "prep"),
                    "--out-root", str(d / "train"), "--export", str(exp), "--device", "cpu",
                    "--toy", "--batch", "16", "--epochs", "6", "--log-every", "1", "--lr", "3e-3",
                ])
                self.assertEqual(rc, 0)
                run = d / "train" / f"toy-{v}"
                recs = [json.loads(line) for line in (run / "metrics.jsonl").read_text().splitlines()]
                steps = [r for r in recs if "loss" in r]
                ckpts = [r["checkpoint"] for r in recs if "checkpoint" in r]
                self.assertIn("e0.5", ckpts)
                self.assertIn("e6.0", ckpts)
                first = np.mean([r["loss"] for r in steps[:3]])
                last = np.mean([r["loss"] for r in steps[-3:]])
                self.assertLess(last, first - 0.1, v)
                # Correction CE falls below the base model's.
                late = steps[-5:]
                self.assertLess(np.mean([r["ce_correction"] for r in late]),
                                np.mean([r["base_ce_correction"] for r in late]))
                self.assertIn("spgispeech", steps[-1]["per_dataset"])
                m, lam = load_model(run / "model-e6.0.safetensors")
                self.assertEqual((m.variant, lam), (v, 1.0))
                info = json.loads((run / "run.json").read_text())
                self.assertEqual(info["shards"], 4)
                self.assertTrue(info["toy"])
                self.assertFalse((run / "selection.json").exists())


class ExperimentRunTests(unittest.TestCase):
    """The non-toy path end to end on synthetic data: provenance, a dev
    check of every half-epoch checkpoint (fake lf-bias-eval) and selection."""

    def test_experiment_run_checks_every_checkpoint_and_selects(self):
        with tempfile.TemporaryDirectory() as d:
            d = Path(d)
            export, prep, _ = make_prep(d, sessions=1, joint=True)
            cmd, res = fake_eval(d)
            # Evaluation reports the synthetic shards' DF table (the run's train_df).
            with mock.patch.dict(os.environ, {"FAKE_EVAL_DF": TRAIN_DF}):
                rc = run_train([
                    "--variant", "L1", "--run", "exp", "--prep", str(prep), "--out-root", str(d / "train"),
                    "--export", str(export), "--device", "cpu", "--batch", "16", "--epochs", "2",
                    "--dev-check-cmd", cmd, "--dev-check-results", res,
                ])
            self.assertEqual(rc, 0)
            run = d / "train" / "exp"
            info = json.loads((run / "run.json").read_text())
            self.assertFalse(info["toy"])
            self.assertEqual(info["checkpoints"], ["e0.5", "e1.0", "e1.5", "e2.0"])
            self.assertEqual(info["checkpoints_planned"], info["checkpoints"])
            self.assertEqual(info["calls"], 3)
            self.assertEqual(set(json.loads((run / "devcheck.json").read_text())), set(info["checkpoints"]))
            sel = json.loads((run / "selection.json").read_text())
            self.assertEqual((sel["selected"]["lambda"], sel["selected"]["objective"]), (1.0, 0.97))
            self.assertIn(sel["selected"]["checkpoint"], info["checkpoints"])
            self.assertEqual((run / "calls.txt").read_text().split(),
                             ["icsi/S000", "slidespeech/S000", f"spgispeech/{SPGI_TRAIN[0]}"])
            self.assertEqual(set(info["datasets"]), {"spgispeech", "slidespeech", "icsi"})

    def test_experiment_run_requires_a_valid_dev_command(self):
        with tempfile.TemporaryDirectory() as d:
            d = Path(d)
            export, prep, _ = make_prep(d, sessions=1)
            base = ["--variant", "L1", "--run", "exp", "--prep", str(prep), "--out-root", str(d / "train"),
                    "--export", str(export), "--device", "cpu"]
            for extra in ([], ["--dev-check-cmd", fake_eval(d)[0] + " --limit 5"]):
                with self.assertRaises(SystemExit) as cm:
                    run_train(base + extra)
                self.assertIn("refusing to train", str(cm.exception))
            with self.assertRaises(SystemExit):
                run_train(base + ["--max-steps", "3"])  # toy-only option


if __name__ == "__main__":
    unittest.main()
