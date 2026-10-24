"""W6 fine-tuning, the hash-pinned load path, identity binding and the Mac bundle (DESIGN 1, 4, 7)."""

from __future__ import annotations

import json
import shutil
import tempfile
import unittest
from pathlib import Path

import numpy as np
import torch

from lfspk.extract.frontend import analytic_mel_power
from lfspk.extract.harness_frontend import save_checkpoint
from lfspk.extract.model import MaskNet, config_for
from lfspk.personal import macbench as MB
from lfspk.personal import tune as T
from tests.test_W6_stream import fake_bank, make_dictation


def _base(path: Path, alpha=3.0, seed=0) -> str:
    torch.manual_seed(seed)
    net = MaskNet(config_for("M", "film_cos"))
    with torch.no_grad():  # move FiLM / head off their zero init so gradients reach every adapted group
        for n, p in net.named_parameters():
            p.add_(0.01 * torch.randn_like(p))
    save_checkpoint(path, net, {"identity": {"effective": {"alpha": alpha}}})
    return MB._sha(path)


def _cfg(**kw):
    base = dict(arm="A-VB", subject="2775", config="P", steps=3, batch=2, crop_frames=100, warmup=2, readouts=(1, 3),
                device="cpu", threads=1)
    base.update(kw)
    return T.TuneConfig(**base)


class Fixture(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.base = self.tmp / "base.pt"
        self.pins = {"VB-s0": _base(self.base)}
        rng = np.random.default_rng(5)
        self.inputs = T.Inputs([make_dictation(rng) for _ in range(10)], fake_bank(), np.ones(192, np.float32) / np.sqrt(192),
                               self.base, {"test": True})
        self.code = {"w6_tune_code_sha256": "x", "w5_code_sha256": "y"}

    def tearDown(self):
        shutil.rmtree(self.tmp)

    def run_tune(self, name, keep_net=False, **kw):
        return T.tune(_cfg(**kw), self.inputs, self.tmp / name, code=self.code, mel=analytic_mel_power(), pins=self.pins,
                      log_every=1, _keep_net=keep_net)


class TestTune(Fixture):
    def test_trained_model_frozen_params_unchanged(self):
        # code2-r1 m3: the in-memory trained network itself, not a reconstruction from the base
        res = self.run_tune("m", keep_net=True)
        trained = {n: p.detach().cpu() for n, p in res["_net"].named_parameters()}
        base, _, _ = T.load_base(self.base, "VB-s0", self.pins)
        adapted = set(T.adapted_names(base, "P"))
        for n, p in base.named_parameters():
            if n not in adapted:
                self.assertTrue(torch.equal(trained[n], p), n)
        self.assertTrue(any(not torch.equal(trained[n], dict(base.named_parameters())[n]) for n in adapted))

    def test_frozen_unchanged_adapted_changed(self):
        self.run_tune("a")
        net, ident, _ = T.load_tuned(self.tmp / "a" / "step3.pt", self.base, self.pins)
        base, _, _ = T.load_base(self.base, "VB-s0", self.pins)
        tuned, ref = dict(net.named_parameters()), dict(base.named_parameters())
        adapted = set(T.adapted_names(base, "P"))
        self.assertEqual(ident["n_adapted"], T.P_COUNT)
        for n in ref:
            if n in adapted:
                continue
            self.assertTrue(torch.equal(tuned[n], ref[n]), n)
        self.assertTrue(any(not torch.equal(tuned[n], ref[n]) for n in adapted))
        for g in T.P_GROUPS:
            self.assertTrue(any(not torch.equal(tuned[n], ref[n]) for n in adapted if n.startswith(g + ".")), g)

    def test_full_changes_trunk(self):
        self.run_tune("f", config="F")
        net, ident, _ = T.load_tuned(self.tmp / "f" / "step3.pt", self.base, self.pins)
        base, _, _ = T.load_base(self.base, "VB-s0", self.pins)
        self.assertFalse(torch.equal(dict(net.named_parameters())["blocks.0.pw1.weight"],
                                     dict(base.named_parameters())["blocks.0.pw1.weight"]))
        self.assertEqual(ident["n_adapted"], sum(p.numel() for p in base.parameters()))

    def test_deterministic_and_readouts(self):
        r1 = self.run_tune("a")
        r2 = self.run_tune("b")
        self.assertEqual(sorted(r1["readouts"]), ["1", "3"])
        a = torch.load(self.tmp / "a" / "step3.pt", weights_only=True)["adapted"]
        b = torch.load(self.tmp / "b" / "step3.pt", weights_only=True)["adapted"]
        self.assertTrue(all(torch.equal(a[k], b[k]) for k in a))
        self.assertEqual(r1["identity_sha256"], r2["identity_sha256"])
        with self.assertRaises(FileExistsError):
            self.run_tune("a")

    def test_load_refusals(self):
        self.run_tune("a")
        p = self.tmp / "a" / "step3.pt"
        with self.assertRaises(RuntimeError):  # another pin
            T.load_tuned(p, self.base, {"VB-s0": "0" * 64})
        with self.assertRaises(RuntimeError):  # another run identity
            T.load_tuned(p, self.base, self.pins, expect_identity_sha256="0" * 64)
        ck = torch.load(p, weights_only=True)
        ck["adapted"].pop("proj.weight")
        torch.save(ck, self.tmp / "bad.pt")
        with self.assertRaises(RuntimeError):  # adapted set differs from configuration P
            T.load_tuned(self.tmp / "bad.pt", self.base, self.pins)
        ck = torch.load(p, weights_only=True)
        ck["identity"]["alpha"] = 10.0
        torch.save(ck, self.tmp / "bad2.pt")
        with self.assertRaises(RuntimeError):  # identity edited without its digest
            T.load_tuned(self.tmp / "bad2.pt", self.base, self.pins)

    def test_base_pin_and_alpha(self):
        with self.assertRaises(RuntimeError):
            T.load_base(self.base, "VB-s0", {"VB-s0": "1" * 64})
        b10 = self.tmp / "b10.pt"
        pins = {"VB-s0": _base(b10, alpha=10.0)}
        inp = T.Inputs(self.inputs.dictations, self.inputs.bank, self.inputs.profile, b10, {})
        with self.assertRaises(RuntimeError):  # A-VB requires the alpha-3 base
            T.tune(_cfg(), inp, self.tmp / "x", code=self.code, mel=analytic_mel_power(), pins=pins)


class TestConfig(unittest.TestCase):
    def test_lr(self):
        c = T.TuneConfig(arm="A-V0", subject="639", device="cpu")
        self.assertAlmostEqual(T.lr_at(0, c), 3e-4 / 50)
        self.assertAlmostEqual(T.lr_at(49, c), 3e-4)
        self.assertAlmostEqual(T.lr_at(999, c), 3e-4)

    def test_pilot_fixed(self):
        T.check_pilot(T.TuneConfig(arm="A-V0", subject="639", device="cpu"))
        with self.assertRaises(ValueError):
            T.check_pilot(_cfg())
        with self.assertRaises(ValueError):
            T.TuneConfig(arm="A-V0", subject="99999")
        with self.assertRaises(ValueError):
            T.TuneConfig(arm="A-V0", subject="639", readouts=(250, 500))


SAMPLE_TIME = """{"step": 1}
      612.34 real       900.10 user        12.50 sys
           734003200  maximum resident set size
                   0  average shared memory size
               52341  page reclaims
           612368384  peak memory footprint
"""


class TestMacbench(Fixture):
    def test_power_snapshot_report_only(self):
        from unittest import mock

        fake = mock.Mock(returncode=0, stdout="Now drawing from 'AC Power'\n -InternalBattery-0 (id=1) 100%; charged", stderr="")
        with mock.patch.object(MB.subprocess, "run", return_value=fake):
            snap = MB.power_snapshot()
        self.assertTrue(snap["on_ac"])
        self.assertEqual(len(snap["load"]), 3)
        with mock.patch.object(MB.subprocess, "run", side_effect=OSError("no pmset")):
            snap = MB.power_snapshot()  # off macOS: recorded as unavailable, never raises
        self.assertIn("unavailable", snap["pmset_batt"])
        self.assertIsNone(snap["on_ac"])

    def test_parse_fails_closed(self):
        # code2-r1 M1: a decimal-comma report parsed as 34 s before; now it fails closed (and cannot pass the budget)
        comma = SAMPLE_TIME.replace("612.34 real       900.10 user        12.50 sys",
                                    "1212,34 real       900,10 user        12,50 sys")
        with self.assertRaises(ValueError):
            MB.parse_time_l(comma)
        with self.assertRaises(ValueError):  # a duplicated field
            MB.parse_time_l(SAMPLE_TIME + "           612368384  peak memory footprint\n")
        with self.assertRaises(ValueError):  # a suffix of a malformed number
            MB.parse_time_l(SAMPLE_TIME.replace("734003200  maximum", "7340x03200  maximum"))

    def test_parse_time(self):
        m = MB.parse_time_l(SAMPLE_TIME)
        self.assertEqual(m["wall_s"], 612.34)
        self.assertEqual(m["max_rss_bytes"], 734003200)
        self.assertEqual(m["peak_footprint_bytes"], 612368384)
        self.assertTrue(MB.within_budget(m))
        self.assertFalse(MB.within_budget({**m, "wall_s": 1201.0}))
        self.assertFalse(MB.within_budget({**m, "peak_footprint_bytes": int(1.6 * 2**30)}))
        with self.assertRaises(ValueError):
            MB.parse_time_l("12.0 real")

    def _bundle(self):
        """A synthetic bundle laid out like `macbench.bundle`, built from the fixture's inputs."""
        from lfspk.personal import render as R
        from lfspk.personal.profiles import vec_sha256
        from lfspk.personal.signals import arrays_digest
        from tests.test_W6_render import _write

        root = self.tmp / "bundle"
        art = root / "art"
        d = art / "runs" / "W5" / "train" / "VB-s0"
        d.mkdir(parents=True)
        shutil.copy2(self.base, d / "final.pt")
        stage = self.tmp / "stage"
        keys = [f"{f}-{i:03d}" for f in R.SCEN for i in range(2)]
        _write(stage, "bank", keys, {"set": "bank"}, f16=True, n_base=32000)
        R.finish("bank", stage, keys=keys)
        R.pack(stage, identity_fn=lambda n: {"set": "bank"}, keys=keys)
        shutil.copytree(stage / R.PACK, art / "runs" / "W6" / "render" / "bank_pack")
        sd = root / "subjects" / "2775"
        sd.mkdir(parents=True)
        digests = {}
        for j, dct in enumerate(self.inputs.dictations):
            arrs = {"audio": dct.audio, "target": dct.target, "target_active": dct.target_active,
                    "info": np.array(json.dumps({"j": j}))}
            np.savez(sd / f"2775-{j:02d}.npz", **arrs)
            digests[f"2775-{j:02d}"] = arrays_digest(arrs)
        np.save(sd / "p0.npy", self.inputs.profile)
        pack_sha = MB._sha(art / "runs" / "W6" / "render" / "bank_pack" / "pack.json")
        files = {str(p.relative_to(root)): MB._sha(p) for p in sorted(root.rglob("*")) if p.is_file()}
        meta = {"files": files, "code": {"w6_tune_code_sha256": T.code_sha256(), "w5_code_sha256": T.w5_code_sha256()},
                "bank_pack_sha256": pack_sha,
                "provenance": {"2775": {"dict_digests": digests, "profile_sha256": vec_sha256(self.inputs.profile),
                                        "bank_pack_sha256": pack_sha}}}
        (root / "bundle.json").write_text(json.dumps(meta))
        return root

    def test_bundle_inputs_and_tamper(self):
        from unittest import mock

        root = self._bundle()
        MB.verify(root)
        cfg = _cfg()
        with mock.patch.object(MB.paths, "ART", root / "art"):
            inp, code = MB.bundle_inputs(root, cfg, _verify_modules=False)  # origin check: TestModuleOrigins
            self.assertEqual(len(inp.dictations), 10)
            np.testing.assert_array_equal(inp.dictations[3].audio, self.inputs.dictations[3].audio)
            res = T.tune(cfg, inp, self.tmp / "mac", code=code, mel=analytic_mel_power(), pins=self.pins)
            self.assertIn("3", res["readouts"])
            with self.assertRaises(RuntimeError):  # wrong LFSPK_ART
                with mock.patch.object(MB.paths, "ART", self.tmp):
                    MB.bundle_inputs(root, cfg, _verify_modules=False)
        (root / "subjects" / "2775" / "extra.txt").write_text("x")
        with self.assertRaises(RuntimeError):
            MB.verify(root)
        (root / "subjects" / "2775" / "extra.txt").unlink()
        np.save(root / "subjects" / "2775" / "p0.npy", -self.inputs.profile)
        with self.assertRaises(RuntimeError):
            MB.verify(root)
        with self.assertRaises(RuntimeError):
            MB.verify(root, bundle_sha256="0" * 64)


if __name__ == "__main__":
    unittest.main()


def _code_bundle(root: Path) -> Path:
    """A bundle holding only the code tree (as macbench.bundle copies it) and a bundle.json listing its hashes."""
    repo = Path(__file__).resolve().parents[1]
    for g in MB.CODE_GLOBS:
        for src in sorted(repo.glob(g)):
            dst = root / "code" / src.relative_to(repo)
            dst.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(src, dst)
    files = {str(p.relative_to(root)): MB._sha(p) for p in sorted(root.rglob("*")) if p.is_file()}
    (root / "bundle.json").write_text(json.dumps({"files": files}))
    return root


class TestModuleOrigins(unittest.TestCase):
    """code2-r1 M2: a verified bundle must be executed from its own code tree, module by module."""

    def _run(self, root: Path, pythonpath: Path, code: str, isolated: bool = True):
        import os
        import subprocess
        import sys

        env = dict(os.environ, PYTHONPATH=str(pythonpath))
        env.pop("PYTHONDONTWRITEBYTECODE", None)
        env.pop("PYTHONPYCACHEPREFIX", None)
        argv = MB.python_argv(MB.fresh_prefix()) if isolated else [sys.executable, "-B"]
        return subprocess.run([*argv, "-P", "-c", code, str(root)], env=env, cwd=str(root), capture_output=True,
                              text=True, timeout=300)

    def _check(self, root: Path, pythonpath: Path):
        code = ("import sys; from pathlib import Path; from lfspk.personal import macbench as M; "
                "M.require_isolated_bytecode(Path(sys.argv[1])); M.preload(); print(M.verify_modules(sys.argv[1]))")
        return self._run(root, pythonpath, code)

    def test_stale_bytecode_cannot_execute(self):
        """code2-r2: in-tree bytecode compiled from other source, with the pinned source's mtime and size, must not
        execute under the bundle launch, and the bundle must be refused while it holds bytecode."""
        import importlib.util
        import os
        import py_compile

        with tempfile.TemporaryDirectory() as t:
            root = _code_bundle(Path(t) / "bundle")
            src = root / "code" / "lfspk" / "pvad" / "features.py"
            evil = Path(t) / "features.py"
            evil.write_text(src.read_text().replace("PREEMPH = 0.97", "PREEMPH = 0.50", 1))
            st = src.stat()
            self.assertEqual(evil.stat().st_size, st.st_size)
            os.utime(evil, ns=(st.st_atime_ns, st.st_mtime_ns))
            py_compile.compile(str(evil), cfile=importlib.util.cache_from_source(str(src)), doraise=True)
            probe = "import lfspk.pvad.features as f; print(f.PREEMPH)"
            plain = self._run(root, root / "code", probe, isolated=False)  # the attack, without the prefix
            self.assertEqual(plain.stdout.strip(), "0.5", plain.stderr[-1000:])
            iso = self._run(root, root / "code", probe)  # the bundle launch never reads in-tree caches
            self.assertEqual(iso.stdout.strip(), "0.97", iso.stderr[-1000:])
            with self.assertRaises(RuntimeError):  # and the bundle is refused while it holds bytecode
                MB.verify(root)

    def test_launch_without_isolation_refused(self):
        with tempfile.TemporaryDirectory() as t:
            root = _code_bundle(Path(t) / "bundle")
            code = ("import sys; from pathlib import Path; from lfspk.personal import macbench as M; "
                    "M.require_isolated_bytecode(Path(sys.argv[1]))")
            bad = self._run(root, root / "code", code, isolated=False)
            self.assertNotEqual(bad.returncode, 0)
            self.assertIn("pycache_prefix", bad.stderr)

    def test_origins(self):
        with tempfile.TemporaryDirectory() as t:
            root = _code_bundle(Path(t) / "bundle")
            ok = self._check(root, root / "code")
            self.assertEqual(ok.returncode, 0, ok.stderr[-2000:])
            self.assertGreaterEqual(int(ok.stdout.strip().splitlines()[-1]), len(MB.PRELOAD))
            # an alternate tree with only pvad/features.py changed, the untouched bundle still verifying
            alt = Path(t) / "alt"
            shutil.copytree(root / "code", alt)
            f = alt / "lfspk" / "pvad" / "features.py"
            txt = f.read_text()
            self.assertIn("0.97", txt)
            f.write_text(txt.replace("0.97", "0.50", 1))
            bad = self._check(root, alt)
            self.assertNotEqual(bad.returncode, 0)
            self.assertIn("outside the verified bundle code", bad.stderr)
            # the bundle's own helper edited after the manifest
            g = root / "code" / "lfspk" / "pvad" / "features.py"
            g.write_text(g.read_text().replace("0.97", "0.50", 1))
            bad2 = self._check(root, root / "code")
            self.assertNotEqual(bad2.returncode, 0)
            self.assertIn("differs from bundle.json", bad2.stderr)


class TestTar(unittest.TestCase):
    def test_tar_round_trip_and_receive_command(self):
        import tarfile

        with tempfile.TemporaryDirectory() as t:
            root = _code_bundle(Path(t) / "macbundle")
            res = MB.make_tar(root, Path(t) / "w6.tar")
            self.assertEqual(res["tar_sha256"], MB._sha(Path(t) / "w6.tar"))
            out = Path(t) / "x"
            with tarfile.open(Path(t) / "w6.tar") as tf:
                tf.extractall(out, filter="data")
            MB.verify(out / "bundle", res["bundle_json_sha256"])
            argv = MB.mac_receive_command("w6.tar", res["tar_sha256"], res["bundle_json_sha256"])
            script = argv[-1]
            self.assertIn(res["tar_sha256"], script)
            self.assertIn(res["bundle_json_sha256"], script)
            self.assertLess(script.index("tailscale file get"), script.index("shasum"))
            self.assertLess(script.index("shasum"), script.index("tar -xf"))
            self.assertLess(script.index("macbench verify"), script.index("rm -f"))
            self.assertIn("-B -X pycache_prefix", script)
            self.assertIn("-B -X pycache_prefix", MB.mac_measure_command("A-VB", "2775", 1, "/o")[-1])
            with self.assertRaises(FileExistsError):
                MB.make_tar(root, Path(t) / "w6.tar")
