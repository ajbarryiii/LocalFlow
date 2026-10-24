"""Contracts of the extraction plumbing that do not need NeMo or a GPU."""

import json
import tempfile
import unittest
from pathlib import Path

import numpy as np

from lfspk.probe import closedset, colour, extract, verify


class TestPrefetch(unittest.TestCase):
    def test_loader_error_propagates(self):
        def bad(item):
            raise OSError("cannot decode")
        with self.assertRaises(RuntimeError) as ctx:
            list(extract.prefetch([0, 1, 2], [[0, 1], [2]], workers=2, load=bad))
        self.assertIsInstance(ctx.exception.__cause__, OSError)

    def test_order(self):
        got = list(extract.prefetch(list("abc"), [[2], [0, 1]], workers=2, load=lambda it: (it, {"x": it})))
        self.assertEqual([g[0] for g in got], [[2], [0, 1]])
        self.assertEqual(got[1][1], ["a", "b"])


class TestInvariance(unittest.TestCase):
    def test_check(self):
        verify.check_invariance({"batch_invariance_max_rel": {"base": 1e-6, "logmel": 1e-9}}, "x")
        with self.assertRaises(ValueError):
            verify.check_invariance({"batch_invariance_max_rel": {"base": 2e-3}}, "x")
        with self.assertRaises(ValueError):
            verify.check_invariance({"batch_invariance_max_rel": {"base": float("nan")}}, "x")
        with self.assertRaises(ValueError):
            verify.check_invariance({"batch_invariance_max_rel": None}, "x")

    def test_load_feats_refuses_bad_record(self):
        with tempfile.TemporaryDirectory() as tmp:
            d = Path(tmp) / "base" / "dev"
            d.mkdir(parents=True)
            np.save(d / "features.npy", np.zeros((1, 1, 2), np.float16))
            for f in ("index.json", "selection.json"):
                (d / f).write_text("[]" if f == "index.json" else "{}")
            (d / "meta.json").write_text('{"limit": 0, "batch_invariance_max_rel": {"base": 0.5}}')
            with self.assertRaises(ValueError):
                verify.load_feats("base", "dev", Path(tmp))


class TestColour(unittest.TestCase):
    def test_response(self):
        from scipy.signal import sosfreqz

        w, h = sosfreqz(colour.sos(), worN=[100, 1000, 3000, 7500], fs=16000)
        db = 20 * np.log10(np.abs(h))
        self.assertLess(db[0], -5)  # high-pass
        self.assertAlmostEqual(db[1], 0.6, delta=1.0)
        self.assertGreater(db[2], 4.0)  # presence peak
        self.assertLess(db[3], -10)  # low-pass

    def test_peak_and_dtype(self):
        x = np.sin(np.arange(16000) * 2 * np.pi * 3000 / 16000).astype(np.float32) * 0.9
        y = colour.colour(x)
        self.assertEqual(y.dtype, np.float32)
        self.assertLessEqual(np.abs(y).max(), 0.99 + 1e-6)

    def test_item_colouring_only_on_test(self):
        import soundfile as sf

        with tempfile.TemporaryDirectory() as tmp:
            p = Path(tmp) / "x.flac"
            sf.write(p, (0.1 * np.random.default_rng(0).normal(size=48000)).astype(np.float32), 16000)
            enroll = extract.Item("1-1-0001", "1", "full", str(p), "enroll")
            test = extract.Item("1-1-0001", "1", "2s", str(p), "test")
            a, ia = extract.load_item(enroll, coloured=True)
            b, ib = extract.load_item(test, coloured=True)
            c, ic = extract.load_item(test, coloured=False)
            self.assertFalse(ia["coloured"])
            self.assertTrue(ib["coloured"])
            self.assertEqual((ib["start"], ib["samples"]), (ic["start"], ic["samples"]))  # same crop
            self.assertFalse(np.allclose(b, c))


class TestClosedSetSplit(unittest.TestCase):
    def test_prefers_cross_project_pair(self):
        sel, proj = {}, {}
        for s in range(1, 260):
            utts = [f"{s}-{10 * s + c}-{i:04d}" for c in range(3) for i in range(4)]
            sel[str(s)] = utts
            # chapters c0, c1 share a project; c2 is another project for odd speakers
            proj[str(10 * s)] = proj[str(10 * s + 1)] = f"p{s}"
            proj[str(10 * s + 2)] = f"q{s}" if s % 2 else f"p{s}"
        split = closedset.choose_split(sel, proj)
        self.assertEqual(len(split), closedset.N_SPEAKERS)
        for spk, (a, b, cross) in split.items():
            self.assertEqual(cross, int(spk) % 2 == 1)
            ca, cb = {u.split("-")[1] for u in a}, {u.split("-")[1] for u in b}
            self.assertEqual(len(ca), 1)
            self.assertEqual(len(cb), 1)
            self.assertNotEqual(ca, cb)
            if cross:
                self.assertNotEqual(proj[ca.pop()], proj[cb.pop()])



class TestInvarianceRel(unittest.TestCase):
    def test_values_and_nonfinite(self):
        self.assertAlmostEqual(extract.invariance_rel(np.array([2.0, -4.0]), np.array([2.0, -3.996])), 1e-3)
        for bad in (np.array([np.nan, 1.0]), np.array([np.inf, 1.0])):
            with self.assertRaises(RuntimeError):
                extract.invariance_rel(bad, np.array([1.0, 1.0]))
            with self.assertRaises(RuntimeError):
                extract.invariance_rel(np.array([1.0, 1.0]), bad)


class TestSubsetAccuracies(unittest.TestCase):
    def test_empty_subset_is_nan(self):
        yb = np.repeat(np.arange(4), 3)
        correct = (np.arange(12) % 2).astype(float)
        out = closedset.subset_accuracies(correct, yb, np.zeros(4, bool), n_boot=50)
        self.assertTrue(np.isnan(out["accuracy_cross_project"]["value"]))
        self.assertAlmostEqual(out["accuracy"]["value"], 0.5)
        self.assertAlmostEqual(out["accuracy_same_project"]["value"], 0.5)

    def test_split_by_flag(self):
        yb = np.repeat(np.arange(4), 2)
        correct = np.array([1, 1, 1, 1, 0, 0, 0, 0], float)
        out = closedset.subset_accuracies(correct, yb, np.array([True, True, False, False]), n_boot=50)
        self.assertEqual(out["accuracy_cross_project"]["value"], 1.0)
        self.assertEqual(out["accuracy_same_project"]["value"], 0.0)
        self.assertEqual((out["accuracy_cross_project"]["lo"], out["accuracy_cross_project"]["hi"]), (1.0, 1.0))



class TestSmokeGuard(unittest.TestCase):
    def setUp(self):
        import os
        self._env = os.environ.get("LFSPK_W2_SMOKE")
        os.environ["LFSPK_W2_SMOKE"] = "1"

    def tearDown(self):
        import os
        if self._env is None:
            os.environ.pop("LFSPK_W2_SMOKE", None)
        else:
            os.environ["LFSPK_W2_SMOKE"] = self._env

    def test_resolved_paths(self):
        from lfspk.probe import guard
        real = "/mnt/hd/localflow-speaker/runs/W2/feats/base/dev"
        self.assertTrue(guard.in_production(real))
        self.assertTrue(guard.in_production("/mnt/hd/localflow-speaker/../localflow-speaker/runs/W2/feats/base"))
        self.assertTrue(guard.in_production("/mnt/hd/localflow-speaker/runs/W2/scratch/../frames/x"))
        self.assertTrue(guard.in_production("/mnt/hd/localflow-speaker"))  # above production
        self.assertFalse(guard.in_production("/mnt/hd/localflow-speaker/runs/W2/scratch/art/runs/W2/feats"))
        with self.assertRaises(ValueError):
            guard.require_scratch("/mnt/hd/localflow-speaker/../localflow-speaker/runs/W2/verify", "t")
        guard.require_scratch("/mnt/hd/localflow-speaker/runs/W2/scratch/art/runs/W2/feats", "t")

    def test_env_required(self):
        import os
        from lfspk.probe import guard
        os.environ.pop("LFSPK_W2_SMOKE")
        with self.assertRaises(ValueError):
            guard.require_scratch("/tmp/x", "t")

    def test_extract_out(self):
        with self.assertRaises(ValueError):
            extract.check_output(Path("/mnt/hd/localflow-speaker/runs/W2/feats"), smoke=True)
        with self.assertRaises(ValueError):
            extract.check_output(Path("/mnt/hd/localflow-speaker/runs/W2/scratch/../feats"), smoke=True)
        extract.check_output(Path("/mnt/hd/localflow-speaker/runs/W2/feats"), smoke=False)
        extract.check_output(Path("/mnt/hd/localflow-speaker/runs/W2/scratch/feats"), smoke=True)

    def test_load_feats_refuses_smoke_in_production_spelling(self):
        """A smoke feature set reached through a path that resolves into production is refused."""
        from lfspk.probe import guard
        with tempfile.TemporaryDirectory() as tmp:
            d = Path(tmp) / "base" / "dev"
            d.mkdir(parents=True)
            np.save(d / "features.npy", np.zeros((1, 1, 2), np.float16))
            (d / "index.json").write_text("[]")
            (d / "selection.json").write_text("{}")
            (d / "meta.json").write_text('{"limit": 5, "batch_invariance_max_rel": {"base": 0.0}}')
            verify.load_feats("base", "dev", Path(tmp))  # scratch: allowed
            saved = guard.production_dirs
            guard.production_dirs = lambda: [Path(tmp).resolve()]
            try:
                with self.assertRaises(ValueError):
                    verify.load_feats("base", "dev", Path(tmp) / "base" / "..")
            finally:
                guard.production_dirs = saved



class TestInputChecks(unittest.TestCase):
    def test_guard_check_inputs(self):
        import os
        from lfspk.probe import guard
        saved = os.environ.get("LFSPK_W2_SMOKE")
        os.environ["LFSPK_W2_SMOKE"] = "1"
        try:
            guard.check_inputs([{"limit": 0}, {}], False, "/mnt/hd/localflow-speaker/runs/W2/feats", "t")
            with self.assertRaises(ValueError):
                guard.check_inputs([{"limit": 0}, {"limit": "speakers=4"}], False, "/tmp/x", "t")
            with self.assertRaises(ValueError):
                guard.check_inputs([{"limit": 3}], True, "/mnt/hd/localflow-speaker/runs/W2/frames", "t")
            guard.check_inputs([{"limit": 3}], True, "/mnt/hd/localflow-speaker/runs/W2/scratch/x", "t")
        finally:
            if saved is None:
                os.environ.pop("LFSPK_W2_SMOKE")
            else:
                os.environ["LFSPK_W2_SMOKE"] = saved

    def test_stage3_train_validates_before_touching_outputs(self):
        """A dev feature set from a smoke extraction refuses a non-smoke run, and
        nothing is created or removed first (an existing run.json survives)."""
        from lfspk.probe import stage3
        with tempfile.TemporaryDirectory() as tmp:
            out = Path(tmp) / "frames"
            run_dir = out / "base-seed1"
            run_dir.mkdir(parents=True)
            (run_dir / "run.json").write_text("{}")
            metas = {("base", "train"): {"limit": 0}, ("logmel", "train"): {"limit": 0},
                     ("base", "dev"): {"limit": "speakers=8"}, ("logmel", "dev"): {"limit": 0}}
            saved = stage3.load_feats, stage3.OUT
            stage3.load_feats = lambda f, sp: (None, [], {}, metas[(f, sp)])
            stage3.OUT = out
            try:
                with self.assertRaises(ValueError):
                    stage3.train("base", 1, 10, smoke=False)
            finally:
                stage3.load_feats, stage3.OUT = saved
            self.assertTrue((run_dir / "run.json").exists())
            self.assertEqual(sorted(p.name for p in out.iterdir()), ["base-seed1"])

    def test_verify_refuses_smoke_without_flag(self):
        with tempfile.TemporaryDirectory() as tmp:
            for split, limit in (("train", 0), ("dev", 7)):
                d = Path(tmp) / "feats" / "base" / split
                d.mkdir(parents=True)
                np.save(d / "features.npy", np.zeros((1, 1, 2), np.float16))
                (d / "index.json").write_text("[]")
                (d / "selection.json").write_text("{}")
                (d / "meta.json").write_text(json.dumps({"limit": limit, "batch_invariance_max_rel": {"base": 0.0}}))
            import os
            saved = os.environ.get("LFSPK_W2_SMOKE")
            os.environ["LFSPK_W2_SMOKE"] = "1"
            try:
                with self.assertRaises(ValueError):
                    verify.score_system("base", None, 8, False, Path(tmp) / "verify" / "base", Path(tmp) / "feats")
            finally:
                if saved is None:
                    os.environ.pop("LFSPK_W2_SMOKE")
                else:
                    os.environ["LFSPK_W2_SMOKE"] = saved
            self.assertFalse((Path(tmp) / "verify").exists())



class TestAudioCache(unittest.TestCase):
    def make(self, tmp, sizes=(16000, 23457, 801)):
        import soundfile as sf
        rng = np.random.default_rng(0)
        where = {}
        for i, n in enumerate(sizes):
            p = Path(tmp) / f"u{i}.flac"
            sf.write(p, rng.integers(-32768, 32767, n).astype(np.int16), 16000, subtype="PCM_16")
            where[f"1-1-{i:04d}"] = str(p)
        return where

    def test_bit_identical_to_soundfile(self):
        import pickle

        import soundfile as sf

        from lfspk.probe import audiocache as AC
        with tempfile.TemporaryDirectory() as tmp:
            where = self.make(tmp)
            gen = AC.build(list(where), where, Path(tmp) / "c")
            cache = AC.AudioCache(Path(tmp) / "c")
            self.assertEqual(cache.generation, gen)
            with self.assertRaises(RuntimeError):
                cache.load("1-1-0000")  # not verified yet
            cache.verify()
            cache = pickle.loads(pickle.dumps(cache))  # as in a DataLoader worker
            for u, p in where.items():
                ref, _ = sf.read(p, dtype="float32")
                got = cache.load(u)
                self.assertEqual(got.dtype, np.float32)
                np.testing.assert_array_equal(got, ref)
            p = Path(tmp) / "bad.flac"
            sf.write(p, np.zeros(100, np.float32), 16000, subtype="PCM_24")
            with self.assertRaises(ValueError):
                AC.build(["x"], {"x": str(p)}, Path(tmp) / "d")

    def test_corruption_is_refused(self):
        import json as js

        from lfspk.probe import audiocache as AC
        with tempfile.TemporaryDirectory() as tmp:
            where = self.make(tmp)
            gen = AC.build(list(where), where, Path(tmp) / "c")
            g = Path(tmp) / "c" / f"gen-{gen}"
            # same-size audio corruption: caught by verify()
            raw = bytearray((g / "audio.int16").read_bytes())
            raw[10] ^= 0xFF
            (g / "audio.int16").write_bytes(bytes(raw))
            c = AC.AudioCache(Path(tmp) / "c")
            with self.assertRaises(ValueError):
                c.verify()
            raw[10] ^= 0xFF
            (g / "audio.int16").write_bytes(bytes(raw))
            AC.AudioCache(Path(tmp) / "c").verify()
            # swapping two utterances' offsets changes the index hash
            idx = js.loads((g / "index.json").read_text())
            good = (g / "index.json").read_bytes()
            idx["1-1-0000"], idx["1-1-0001"] = idx["1-1-0001"], idx["1-1-0000"]
            (g / "index.json").write_text(js.dumps(idx, sort_keys=True))
            with self.assertRaises(ValueError):
                AC.AudioCache(Path(tmp) / "c")
            (g / "index.json").write_bytes(good)
            # metadata edited to match a tampered index no longer matches the generation id
            meta = js.loads((g / "meta.json").read_text())
            meta["audio_sha256"] = "0" * 64
            (g / "meta.json").write_text(js.dumps(meta))
            with self.assertRaises(ValueError):
                AC.AudioCache(Path(tmp) / "c")

    def test_check_index(self):
        from lfspk.probe.audiocache import check_index
        check_index({"a": [0, 2], "b": [2, 2]}, 4)
        for bad in ({"a": [3, 4]}, {"a": [0, 2], "b": [3, 1]}, {"a": [0, 3], "b": [2, 2]},
                    {"a": [0, 0], "b": [0, 4]}, {"a": [-1, 2]}, {"a": [0, 2]}):
            with self.assertRaises(ValueError):
                check_index(bad, 4)

    def test_generations_and_pinning(self):
        from lfspk.probe import audiocache as AC
        with tempfile.TemporaryDirectory() as tmp:
            where = self.make(tmp)
            d = Path(tmp) / "c"
            g1 = AC.build(list(where)[:2], where, d)
            pinned = AC.AudioCache(d)
            self.assertEqual(AC.build(list(where)[:2], where, d), g1)  # same content, same id, kept
            g2 = AC.build(list(where), where, d)
            self.assertNotEqual(g1, g2)
            self.assertEqual(pinned.generation, g1)  # a reader stays on its generation
            self.assertEqual(AC.AudioCache(d).generation, g2)
            self.assertEqual(sorted(p.name for p in d.iterdir()), sorted(["CURRENT", f"gen-{g1}", f"gen-{g2}"]))
            AC.require_ids(AC.AudioCache(d), where, "t")
            with self.assertRaises(ValueError):
                AC.require_ids(pinned, where, "t")

    def test_stage3_dataset_has_no_fallback(self):
        from lfspk.probe import audiocache as AC
        from lfspk.probe import stage3
        with tempfile.TemporaryDirectory() as tmp:
            where = self.make(tmp)
            AC.build(list(where)[:1], where, Path(tmp) / "c")
            c = AC.AudioCache(Path(tmp) / "c")
            c.verify()
            ds = stage3._Mixtures([], 0, False, [c])
            self.assertEqual(ds._load("1-1-0000").size, 16000)
            with self.assertRaises(KeyError):
                ds._load("1-1-0001")  # exists as a FLAC, but not in the cache


if __name__ == "__main__":
    unittest.main()
