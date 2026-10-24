"""W5 fix screen (DESIGN amendment draft d17dade8): VA linear head, VB alpha = 3,
VC profile dropout, each with an unconditioned twin, plus the V0 control."""

from __future__ import annotations

import tempfile
import unittest
from pathlib import Path

import numpy as np
import torch

from lfspk.extract import model as M
from lfspk.extract import train as T
from lfspk.extract.api import LOG_G_MIN


class TestLinearHead(unittest.TestCase):
    def test_default_head_is_unchanged(self):
        self.assertEqual(M.config_for("M").head, "sigmoid")
        torch.manual_seed(0)
        a = M.MaskNet(M.config_for("M"))
        torch.manual_seed(0)
        b = M.MaskNet(M.MaskNetConfig(channels=128))
        x, e = torch.randn(1, 128, 50), torch.randn(1, 192)
        torch.testing.assert_close(a(x, e)[0], b(x, e)[0], rtol=0, atol=0)

    def test_old_checkpoint_config_loads(self):
        from lfspk.extract.harness_frontend import load_checkpoint, save_checkpoint

        net = M.MaskNet(M.config_for("S"))
        with tempfile.TemporaryDirectory() as d:
            p = Path(d) / "c.pt"
            save_checkpoint(p, net, {})
            ck = torch.load(p, weights_only=True)
            ck["config"].pop("head")  # a checkpoint written before the flag existed
            torch.save(ck, p)
            loaded, _, _ = load_checkpoint(p)
            self.assertEqual(loaded.cfg.head, "sigmoid")

    def test_linear_head_init_and_gradient(self):
        torch.manual_seed(0)
        net = M.MaskNet(M.config_for("M", head="linear"))
        x, e = torch.randn(2, 128, 64), torch.randn(2, 192)
        lm, _ = net(x, e)
        torch.testing.assert_close(lm, torch.full_like(lm, M.LINEAR_BIAS_INIT))  # about -0.2 dB everywhere
        lm.sum().backward()
        g = net.mask_head.bias.grad
        # d log m / d bias = 1 inside the range: each bias element receives (T x B) frames' worth
        self.assertTrue(torch.allclose(g, torch.full_like(g, 2 * 32)))

    def test_linear_head_range(self):
        net = M.MaskNet(M.config_for("S", head="linear"))
        with torch.no_grad():
            torch.nn.init.normal_(net.mask_head.weight, std=5.0)
        lm, _ = net(torch.randn(1, 128, 40), torch.randn(1, 192))
        self.assertGreaterEqual(float(lm.min()), LOG_G_MIN - 1e-6)
        self.assertLessEqual(float(lm.max()), 0.0)

    def test_linear_head_clamp_gradient_convention(self):
        # fix-r1 #8: d(log m)/dz = 1 inside [log g_min, 0] (torch.clamp: the bounds themselves pass
        # the gradient) and 0 outside
        z = torch.tensor([LOG_G_MIN - 1.0, LOG_G_MIN, -1.0, 0.0, 0.5], requires_grad=True)
        z.clamp(min=LOG_G_MIN, max=0.0).sum().backward()
        self.assertEqual(z.grad.tolist(), [0.0, 1.0, 1.0, 1.0, 0.0])
        self.assertEqual(M.MaskNetConfig(head="linear").to_dict()["head"], "linear")  # serialised

    def test_unknown_head_refused(self):
        with self.assertRaises(ValueError):
            M.config_for("M", head="tanh")


class TestScreenRuns(unittest.TestCase):
    WANT = {"V0": dict(conditioning="film_cos"), "VA": dict(conditioning="film_cos", head="linear"),
            "VB": dict(conditioning="film_cos", alpha=3.0), "VC": dict(conditioning="film_cos", p_absent=0.5)}

    def test_screen_specs(self):
        for name, want in self.WANT.items():
            for twin, cond in ((name, "film_cos"), (name + "u", "none")):
                spec = T.RUNS[twin]
                self.assertEqual(spec["size"], "M")
                self.assertEqual(spec["target_kind"], "T2")
                self.assertEqual(spec["conditioning"], cond)
                self.assertEqual(spec.get("head", "sigmoid"), want.get("head", "sigmoid"))
                self.assertEqual(spec.get("alpha", T.ALPHA), want.get("alpha", T.ALPHA))
                self.assertEqual(spec.get("p_absent", 0.05), want.get("p_absent", 0.05))
        for r in ("R1", "R2", "R3"):  # the original runs are unchanged
            self.assertNotIn("head", T.RUNS[r])
            self.assertNotIn("alpha", T.RUNS[r])
            self.assertNotIn("p_absent", T.RUNS[r])

    def test_effective_settings(self):
        cfg = T.TrainConfig(run="VB", seed=0, steps=4000)
        self.assertEqual(T.effective(cfg), {"head": "sigmoid", "alpha": 3.0, "p_absent": 0.05})
        self.assertEqual(T.effective(T.TrainConfig(run="R1", seed=0, steps=10)),
                         {"head": "sigmoid", "alpha": T.ALPHA, "p_absent": 0.05})
        with self.assertRaises(ValueError):  # a run's own alpha cannot be overridden from the config
            T.effective(T.TrainConfig(run="VB", seed=0, steps=10, alpha=5.0))

    def test_policy_and_model_follow_the_run(self):
        cfg = T.TrainConfig(run="VC", seed=0, steps=10)
        self.assertEqual(T.example_policy(cfg).p_absent, 0.5)
        self.assertEqual(T.model_config(T.TrainConfig(run="VA", seed=0, steps=10)).head, "linear")
        self.assertEqual(T.model_config(T.TrainConfig(run="VAu", seed=0, steps=10)).conditioning, "none")


class TestScreenStream(unittest.TestCase):
    """VC changes only the absent decisions: the mixtures of example k are the same."""

    @classmethod
    def setUpClass(cls):
        from lfspk.extract.data import ExamplePolicy, ExampleSource
        from lfspk.harness.mix import MixtureGenerator
        from lfspk.harness.synthetic import SyntheticCorpus
        from lfspk.pvad.enrollment import EnrollPolicy, target_eligible

        try:
            from test_W5_data import synthetic_setup
        except ImportError:
            from tests.test_W5_data import synthetic_setup
        cls._ctx = SyntheticCorpus()
        corpus = cls._ctx.__enter__()
        cls.corpus = corpus
        parts, bank, _ = synthetic_setup(corpus)
        gen = MixtureGenerator("dev", corpus=corpus)
        targets = [s for s, p in parts.items() if target_eligible(p)]

        def src(p):
            return ExampleSource(gen, parts, bank, targets, (), ExamplePolicy(p_absent=p, enroll=EnrollPolicy(k_choices=(1,))),
                                 _synthetic_test=True)

        cls.lo, cls.hi = src(0.05), src(0.5)

    @classmethod
    def tearDownClass(cls):
        cls._ctx.__exit__(None, None, None)

    def test_same_mixtures_more_absent(self):
        absent = []
        for k in range(24):
            a, b = self.lo.example(0, k), self.hi.example(0, k)
            np.testing.assert_array_equal(a.audio, b.audio)
            absent.append(b.info["absent"])
            if a.info["absent"]:
                self.assertTrue(b.info["absent"])  # monotone in p: the same uniform draw
        self.assertGreater(sum(absent), 4)

    def test_vc_specification(self):
        # fix-r1 #2: p_absent total 0.5; impostor outside held-out and mixture speakers; T2 target
        # noise only; labels = activity of any remaining voice; the twin sees identical examples
        # except the zeroed profile; target-present S0/N keep the identity target
        from lfspk.extract.data import ExamplePolicy, ExampleSource, identity_labels

        cfg = T.TrainConfig(run="VC", seed=0, steps=2, batch=1, workers=0, device="cpu")
        self.assertEqual(T.example_policy(cfg).p_absent, 0.5)
        self.assertEqual(T.example_policy(T.TrainConfig(run="VCu", seed=0, steps=2)).p_absent, 0.5)
        from lfspk.harness.mix import MixtureGenerator

        excluded = ("103",)
        gen = MixtureGenerator("dev", corpus=self.corpus,
                               speakers=[s for s in sorted(self.hi.partitions, key=int) if s not in excluded])
        src = ExampleSource(gen, self.hi.partitions, self.hi.bank, [t for t in self.hi.targets if t not in excluded],
                            excluded, ExamplePolicy(p_absent=0.5, enroll=self.hi.policy.enroll), _synthetic_test=True)
        twin = ExampleSource(src.gen, src.partitions, src.bank, src.targets, excluded, src.policy, conditioned=False,
                             _synthetic_test=True)
        n_abs = 0
        for fam in ("S0", "N", "S2", "S4"):
            for k in range(10):
                e, u = src.example(1, k, family=fam), twin.example(1, k, family=fam)
                for a, b in ((e.audio, u.audio), (e.target, u.target), (e.interfering, u.interfering)):
                    np.testing.assert_array_equal(a, b)
                self.assertEqual(e.info, u.info)
                self.assertEqual(float(np.abs(u.profile).max()), 0.0)
                if e.info["absent"]:
                    n_abs += 1
                    imp = e.info["impostor"]
                    self.assertNotIn(imp, excluded)
                    self.assertNotEqual(imp, e.info["speaker"])
                    self.assertNotIn(imp, e.info["interferers"])
                    np.testing.assert_allclose(e.target, e.noise, atol=0)
                    want = identity_labels(np.asarray(e.labels) > 0 if fam == "N" else np.isin(e.labels, (1, 3)),
                                           np.isin(e.labels, (2, 3)), True, fam)
                    np.testing.assert_array_equal(e.interfering, want)
                    self.assertTrue(e.interfering.any())
                elif fam in ("S0", "N"):
                    np.testing.assert_allclose(e.target, e.audio, atol=1e-6)
                    self.assertFalse(e.interfering.any())
        self.assertGreaterEqual(n_abs, 8)  # 40 examples at p 0.5: about 20 expected

    def test_stream_refuses_mismatched_policy(self):
        cfg = T.TrainConfig(run="VC", seed=0, steps=2, batch=1, workers=0, device="cpu")
        with self.assertRaises(ValueError):
            T.Stream(cfg, 0, self.lo)  # VC needs p_absent 0.5
        T.Stream(cfg, 0, self.hi).close()


if __name__ == "__main__":
    unittest.main()


class TestFixR2Explicit(unittest.TestCase):
    """fix-r2 #1: screen runs are fully explicit; conflicting values are refused."""

    def test_screen_fixed_fields(self):
        for name in ("V0", "VA", "VB", "VC", "V0u", "VAu", "VBu", "VCu"):
            self.assertEqual(T.RUNS[name]["fixed"], {"steps": 6500, "warmup": 1000, "batch": 32, "workers": 8})

    def test_cli_resolution_and_refusal(self):
        cfg = T.config_from_args(["run", "--run", "VA"])
        self.assertEqual((cfg.steps, cfg.warmup, cfg.batch, cfg.workers), (6500, 1000, 32, 8))
        for bad in (["--steps", "13000"], ["--workers", "6"]):
            with self.assertRaises(SystemExit):
                T.config_from_args(["run", "--run", "VA", *bad])
        T.config_from_args(["run", "--run", "VA", "--steps", "6500", "--workers", "8"])  # equal values are fine
        with self.assertRaises(SystemExit):
            T.config_from_args(["run", "--run", "R1"])  # R1 still needs an explicit --steps
        self.assertEqual(T.config_from_args(["run", "--run", "R1", "--steps", "13000"]).steps, 13000)

    def test_train_refuses_unfixed_screen_config(self):
        with self.assertRaises(ValueError):
            T.check_fixed(T.TrainConfig(run="VA", seed=0, steps=13000, workers=8))
        T.check_fixed(T.TrainConfig(run="VA", seed=0, steps=6500, workers=8))
        T.check_fixed(T.TrainConfig(run="R1", seed=0, steps=13000, workers=3))  # no fixed fields

    def test_screen_lr_schedule(self):
        cfg = T.config_from_args(["run", "--run", "VB"])
        self.assertAlmostEqual(T.lr_at(0, cfg), 2e-3 / 1000)
        self.assertAlmostEqual(T.lr_at(999, cfg), 2e-3)
        self.assertAlmostEqual(T.lr_at(1000 + 2750, cfg), 1e-3, places=12)  # half-way through the 5,500-step cosine
        self.assertLess(T.lr_at(6499, cfg), 1e-9)


class TestFixR2Recipe(unittest.TestCase):
    """fix-r2 #2: R1 and R2 take the screen winner through `recipe`, keeping the run label."""

    def test_default_recipe_unchanged(self):
        cfg = T.TrainConfig(run="R1", seed=0, steps=13000)
        self.assertEqual(cfg.recipe, "V0")
        self.assertEqual(T.effective(cfg), {"head": "sigmoid", "alpha": T.ALPHA, "p_absent": 0.05})
        self.assertEqual(T.model_config(cfg), M.config_for("M", "film_cos"))

    def test_recipe_equals_screen_factor(self):
        for rec in ("VA", "VB", "VC"):
            for run, twin in (("R1", rec), ("R2", rec + "u")):
                a = T.TrainConfig(run=run, seed=0, steps=13000, recipe=rec)
                b = T.TrainConfig(run=twin, seed=0, steps=6500, workers=8)
                self.assertEqual(T.effective(a), T.effective(b))
                self.assertEqual(T.model_config(a), T.model_config(b))
                self.assertEqual(a.name(), f"{run}-s0")  # the label stays eligible
        self.assertEqual(T.config_from_args(["run", "--run", "R1", "--steps", "13000", "--recipe", "VA"]).recipe, "VA")

    def test_recipe_refusals(self):
        with self.assertRaises(ValueError):
            T.TrainConfig(run="R3", seed=0, steps=10, recipe="VA")  # R1 and R2 only
        with self.assertRaises(ValueError):
            T.TrainConfig(run="VA", seed=0, steps=10, recipe="VB")  # screen runs carry their own factor
        with self.assertRaises(ValueError):
            T.TrainConfig(run="R1", seed=0, steps=10, recipe="VD")

    def test_recipe_in_identity(self):
        from dataclasses import asdict

        d = {k: v for k, v in asdict(T.TrainConfig(run="R1", seed=0, steps=10, recipe="VA")).items()
             if k not in T.SAFE_FIELDS}
        self.assertEqual(d["recipe"], "VA")


class TestFixR2Wiring(unittest.TestCase):
    """fix-r2 #3: the alpha the loss consumes and the absent rate the stream emits, through production code."""

    def batch(self):
        torch.manual_seed(1)
        b = {"x": torch.randn(2, 128, 40), "profile": torch.randn(2, 192), "valid": torch.ones(2, 40),
             "labels": (torch.rand(2, 40) > 0.5).float()}
        b["ideal"] = -torch.rand(2, 128, 40) * 3.0
        return b

    def test_step_loss_uses_the_runs_alpha(self):
        from lfspk.extract.losses import aux_loss, mask_loss

        b = self.batch()
        for run, alpha in (("V0", 10.0), ("VB", 3.0)):
            cfg = T.TrainConfig(run=run, seed=0, steps=6500, workers=8)
            net = M.MaskNet(T.model_config(cfg))
            with torch.no_grad():
                torch.nn.init.normal_(net.mask_head.weight, std=0.5)
                net.mask_head.bias.fill_(0.0)  # a mask far from pass-through, so over-suppression occurs
            loss, parts = T.step_loss(net, b, cfg)
            lm, ul = net(b["x"], b["profile"], b["valid"].sum(1).long())
            want = mask_loss(lm, b["ideal"], b["valid"], alpha) + 0.1 * aux_loss(ul, b["labels"], b["valid"])
            self.assertAlmostEqual(float(loss), float(want), places=5)
            other = mask_loss(lm, b["ideal"], b["valid"], 13.0 - alpha)  # the other alpha would differ
            self.assertNotAlmostEqual(float(parts["mask"]), float(other), places=3)

    def test_unconditioned_step_ignores_profile(self):
        cfg = T.TrainConfig(run="VBu", seed=0, steps=6500, workers=8)
        net = M.MaskNet(T.model_config(cfg))
        b = self.batch()
        l1, _ = T.step_loss(net, b, cfg)
        b["profile"] = torch.randn(2, 192) * 9
        l2, _ = T.step_loss(net, b, cfg)
        self.assertEqual(float(l1), float(l2))

    def test_stream_builds_source_with_the_runs_p_absent(self):
        from unittest import mock

        seen = []

        class FakeSrc:
            conditioned = True

            def __init__(self, p):
                self.policy = type("P", (), {"target_kind": "T2", "p_absent": p})()

            def example(self, seed, k):  # what the pool worker calls
                return type("E", (), {})()

        def fake_source(kind, cond, p_absent):
            seen.append((kind, cond, p_absent))
            return FakeSrc(p_absent)

        with mock.patch.object(T, "_source", side_effect=fake_source):
            T.Stream(T.TrainConfig(run="VC", seed=0, steps=1, batch=1, workers=0, device="cpu"), 0).close()
            T.Stream(T.TrainConfig(run="R1", seed=0, steps=1, batch=1, workers=0, device="cpu", recipe="VC"), 0).close()
            T.Stream(T.TrainConfig(run="V0", seed=0, steps=1, batch=1, workers=0, device="cpu"), 0).close()
            T._example((0, 3, "T2", True, 0.5))
        self.assertEqual([s[2] for s in seen[:3]], [0.5, 0.5, 0.05])
        self.assertEqual(seen[3], ("T2", True, 0.5))  # the pool worker forwards p_absent too


class TestFixR2Forward(unittest.TestCase):
    """fix-r2 #4: expected values and gradients through MaskNet.forward."""

    def test_sigmoid_mapping_hand_value(self):
        net = M.MaskNet(M.config_for("S"))  # weights 0, bias 5 at init
        lm, _ = net(torch.randn(1, 128, 10), torch.randn(1, 192))
        want = np.log(1e-3) * (1 - 1 / (1 + np.exp(-5.0)))  # -0.0462324...
        np.testing.assert_allclose(lm.detach().numpy(), want, rtol=0, atol=1e-6)

    def test_linear_gradient_through_forward(self):
        net = M.MaskNet(M.config_for("S", head="linear"))
        vals = torch.full((2 * 128,), -1.0)
        vals[0], vals[1], vals[2], vals[3] = LOG_G_MIN - 0.5, LOG_G_MIN, 0.0, 0.5  # outside, bound, bound, outside
        with torch.no_grad():
            net.mask_head.bias.copy_(vals)
        t = 20
        lm, _ = net(torch.randn(1, 128, t), torch.randn(1, 192))
        self.assertAlmostEqual(float(lm[0, 0, 0]), LOG_G_MIN, places=5)  # clamped up
        self.assertAlmostEqual(float(lm[0, 3, 0]), 0.0, places=6)  # clamped down
        self.assertAlmostEqual(float(lm[0, 4, 0]), -1.0, places=6)
        lm.sum().backward()
        g = net.mask_head.bias.grad[:5].tolist()
        steps = t // 2  # bias channel c feeds the 10 ms frames of sub-frame 0 of every 50 fps step
        self.assertEqual(g, [0.0, float(steps), float(steps), 0.0, float(steps)])


class TestFixR3RealSource(unittest.TestCase):
    """fix-r3 #1: the production `_source` construction and the worker function, with only the
    external data mocked (corpus, partitions, held-out set, bank); the emitted absent flags must
    equal the seeded draws for the run's p_absent."""

    @classmethod
    def setUpClass(cls):
        from lfspk.harness.synthetic import SyntheticCorpus

        try:
            from test_W5_data import synthetic_setup
        except ImportError:
            from tests.test_W5_data import synthetic_setup
        cls._ctx = SyntheticCorpus()
        cls.corpus = cls._ctx.__enter__()
        cls.parts, cls.bank, sex = synthetic_setup(cls.corpus)
        cls.speakers = [type("Spk", (), {"id": s})() for s in sorted(cls.parts, key=int)]

    @classmethod
    def tearDownClass(cls):
        cls._ctx.__exit__(None, None, None)

    def patched(self):
        from contextlib import ExitStack
        from unittest import mock

        from lfspk.harness import mix

        corpus = self.corpus
        real_gen = mix.MixtureGenerator
        st = ExitStack()
        st.enter_context(mock.patch("lfspk.extract.overlay.held_out", return_value=("103",)))
        st.enter_context(mock.patch("lfspk.extract.overlay.load_bank", return_value=(self.bank, {})))
        st.enter_context(mock.patch("lfspk.pvad.enrollment.librispeech_partitions", return_value=self.parts))
        st.enter_context(mock.patch("lfspk.splits.speakers", return_value=self.speakers))
        st.enter_context(mock.patch("lfspk.harness.mix.MixtureGenerator",
                                    side_effect=lambda split, speakers=None: real_gen("dev", corpus=corpus, speakers=speakers)))
        # the synthetic corpus is split "dev"; let ExampleSource accept it (its _synthetic_test flag)
        st.enter_context(mock.patch("lfspk.extract.data.ExampleSource.__init__.__defaults__", (True, True)))
        st.callback(setattr, T, "_SRC", None)
        T._SRC = None
        return st

    def expected_absent(self, seed, ks, p):
        from lfspk.extract.data import example_rngs

        return [bool(example_rngs(seed, k)["absent"].random() < p) for k in ks]

    def test_stream_and_worker_emit_the_seeded_absent_flags(self):
        for run, p in (("VC", 0.5), ("V0", 0.05)):
            with self.patched():
                cfg = T.TrainConfig(run=run, seed=3, steps=12, batch=2, workers=0, device="cpu")
                st = T.Stream(cfg, 0)
                got = [e.info["absent"] for _ in range(12) for e in st.batch()]
                st.close()
            self.assertEqual(got, self.expected_absent(3, range(24), p), run)
        with self.patched():  # the pool worker's function, with the args the stream builds
            cfg = T.TrainConfig(run="VC", seed=3, steps=12, batch=2, workers=2, device="cpu")
            args = (cfg.seed, cfg.spec["target_kind"], True, T.effective(cfg)["p_absent"])
            got = [T._example((args[0], k, *args[1:])).info["absent"] for k in range(24)]
        self.assertEqual(got, self.expected_absent(3, range(24), 0.5))
        self.assertGreater(sum(got), 6)

    def test_source_cache_is_keyed_by_configuration(self):
        with self.patched():
            a = T._source("T2", True, 0.5)
            b = T._source("T2", True, 0.05)
            self.assertEqual((a.policy.p_absent, b.policy.p_absent), (0.5, 0.05))
            self.assertIs(T._source("T2", True, 0.5), a)


class TestFixR3Smoke(unittest.TestCase):
    """fix-r3 #2: `smoke` refuses fixed screen runs up front; resume_check forwards the recipe."""

    def test_smoke_refuses_screen_runs(self):
        from unittest import mock

        with mock.patch.object(T, "train", side_effect=AssertionError("must not train")):
            with self.assertRaises(SystemExit):
                T.main(["smoke", "--run", "VA"])

    def test_resume_check_and_smoke_forward_the_recipe(self):
        from unittest import mock

        seen = []

        def fake_train(cfg, *a, **k):  # records the config; makes the run directory as the real train does
            seen.append(cfg)
            if cfg.out:
                Path(cfg.out).mkdir(parents=True, exist_ok=True)
            return Path(d) / "x.pt"

        with tempfile.TemporaryDirectory() as d, \
                mock.patch.object(T, "train", side_effect=fake_train), \
                mock.patch("lfspk.extract.harness_frontend.load_checkpoint",
                           return_value=(M.MaskNet(M.config_for("S")), {}, "")):
            T.resume_check("R1", 0, 0, "cpu", Path(d), recipe="VC")
            self.assertTrue(seen and all(c.recipe == "VC" for c in seen))
            seen.clear()
            T.main(["smoke", "--run", "R1", "--steps", "4", "--workers", "0", "--device", "cpu", "--recipe", "VC",
                    "--out", str(Path(d) / "sm")])
            self.assertTrue(seen and all(c.recipe == "VC" for c in seen))
