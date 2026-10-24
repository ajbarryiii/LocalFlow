"""Score content identity (code + loaded files) and its use when a word filter
combines several score directories (sol review of W5's identity check: a
changed checkpoint at the same path must not be combined with the old one)."""

import json
import os
import sys
import tempfile
import time
import unittest
from pathlib import Path

import numpy as np

from lfspk.harness import evaluate as E
from lfspk.harness import frontend_eval as FE
from lfspk.harness.frozen import FrozenSet
from tests import w0_frontend_fixtures as X

SPEC = "tests.w0_score_fixtures:make"


def score_dir(d: Path, fs: FrozenSet, half: str, kwargs: dict, content: bool = True) -> Path:
    """An `evaluate run` score directory for one half, written as run_scoring
    writes it, with the content identity of the configuration as it is now."""
    (d / "scores").mkdir(parents=True)
    ident = E.scorer_identity(SPEC, kwargs, fs.set_id, fs.hash)
    (d / "scores" / "IDENTITY.json").write_text(json.dumps(ident, indent=1, sort_keys=True))
    rows = [r for r in fs.manifest if r["half"] == half]
    keys = E.expected_score_keys(fs, rows)
    by = {}
    for k in keys:
        mid = k.rsplit("|", 1)[1]
        row = next(r for r in rows if r["id"] == mid)
        by.setdefault(row["speaker"], {})[k] = np.ones(fs.labels(row)["labels"].size, np.float32)
    for s, v in by.items():
        E.save_scores(d / "scores" / f"{s}.npz", v)
    (d / "scores" / "COMPLETE.json").write_text(json.dumps({"identity": ident["hash"], "n_keys": len(keys), "keys_sha256": E._keys_hash(keys)}))
    if content:
        E.write_content_identity(d / "scores", E.content_identity(SPEC, kwargs), ident)
    return d


class ContentIdentityTest(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory(dir="/tmp")
        self.t = Path(self._tmp.name)
        self.ckpt = self.t / "ckpt.bin"
        self.ckpt.write_bytes(b"weights v1")

    def tearDown(self):
        self._tmp.cleanup()

    def test_hashes_code_and_loaded_files(self):
        ci = E.content_identity(SPEC, {"checkpoint": str(self.ckpt)})
        loaded = dict(ci["loaded"])
        self.assertIn(str(self.ckpt.resolve()), loaded)
        self.assertIn("tests/w0_score_fixtures.py", dict(ci["code"]))
        self.assertIn("lfspk/api.py", dict(ci["code"]))
        self.assertEqual(ci["warmup"], "ok")
        self.assertEqual(E.content_identity(SPEC, {"checkpoint": str(self.ckpt)})["sha256"], ci["sha256"])  # deterministic
        self.ckpt.write_bytes(b"weights v2")  # same path, other bytes
        self.assertNotEqual(E.content_identity(SPEC, {"checkpoint": str(self.ckpt)})["sha256"], ci["sha256"])
        # Interpreter and library files are not part of it.
        self.assertFalse(any(p.endswith((".py", ".pyc", ".so")) for p in loaded))

    def test_lazy_load_on_first_score_is_captured(self):
        ci = E.content_identity(SPEC, {"checkpoint": str(self.ckpt), "lazy": "1"})
        self.assertIn(str(self.ckpt.resolve()), dict(ci["loaded"]))

    def test_content_file_is_bound_to_the_score_identity(self):
        fs = FrozenSet("fake-set", root=X.build_set(self.t / "set"))
        d = score_dir(self.t / "A", fs, "A", {"checkpoint": str(self.ckpt)})
        c = json.loads((d / "scores" / "CONTENT.json").read_text())
        self.assertEqual(c["identity_sha256"], json.loads((d / "scores" / "IDENTITY.json").read_text())["hash"])
        self.assertFalse(c["backfilled"])


class CombinationTest(unittest.TestCase):
    """The failure scenario: score half A, change the checkpoint bytes at the same
    path, score half B; both halves keep one score identity."""

    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory(dir="/tmp")
        self.t = Path(self._tmp.name)
        self.fs = FrozenSet("fake-set", root=X.build_set(self.t / "set"))
        self.ckpt = self.t / "ckpt.bin"
        self.ckpt.write_bytes(b"weights v1")
        self.kw = {"checkpoint": str(self.ckpt)}

    def tearDown(self):
        self._tmp.cleanup()

    def test_changed_checkpoint_at_the_same_path_is_refused(self):
        a = score_dir(self.t / "A", self.fs, "A", self.kw)
        self.ckpt.write_bytes(b"weights v2")
        b = score_dir(self.t / "B", self.fs, "B", self.kw)
        self.assertEqual(json.loads((a / "scores" / "IDENTITY.json").read_text()), json.loads((b / "scores" / "IDENTITY.json").read_text()))
        with self.assertRaisesRegex(SystemExit, "content"):
            FE.load_filter(self.fs, [a, b])

    def test_same_content_combines(self):
        a = score_dir(self.t / "A", self.fs, "A", self.kw)
        b = score_dir(self.t / "B", self.fs, "B", self.kw)
        f = FE.load_filter(self.fs, [a, b])
        self.assertEqual(f.content_sha256, json.loads((a / "scores" / "CONTENT.json").read_text())["sha256"])

    def test_missing_or_foreign_content_identity_refused(self):
        a = score_dir(self.t / "A", self.fs, "A", self.kw, content=False)
        with self.assertRaisesRegex(SystemExit, "content"):
            FE.load_filter(self.fs, [a])
        b = score_dir(self.t / "B", self.fs, "B", self.kw)
        c = json.loads((b / "scores" / "CONTENT.json").read_text())
        (b / "scores" / "CONTENT.json").write_text(json.dumps({**c, "identity_sha256": "0" * 64}))
        with self.assertRaisesRegex(SystemExit, "content"):
            FE.load_filter(self.fs, [b])


class BackfillTest(unittest.TestCase):
    """Directories scored before content identities existed (W1 Stage D 00-05):
    a content identity is recorded only if nothing it covers was modified after
    the scoring completed."""

    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory(dir="/tmp")
        self.t = Path(self._tmp.name)
        self.fs = FrozenSet("fake-set", root=X.build_set(self.t / "set"))
        self.ckpt = self.t / "ckpt.bin"
        self.ckpt.write_bytes(b"weights v1")
        self.kw = {"checkpoint": str(self.ckpt)}

    def tearDown(self):
        self._tmp.cleanup()

    def _complete_at(self, d: Path, when: float) -> None:
        os.utime(d / "scores" / "COMPLETE.json", (when, when))

    def test_backfill_when_nothing_changed_since(self):
        d = score_dir(self.t / "A", self.fs, "A", self.kw, content=False)
        self._complete_at(d, time.time() + 3600)  # completed after every covered file was last written
        c = E.backfill_content(d)
        self.assertTrue(c["backfilled"])
        self.assertEqual(c["evidence"]["rule"], "every covered file's mtime precedes COMPLETE.json")
        self.assertEqual(c["sha256"], E.content_identity(SPEC, self.kw)["sha256"])
        FE.load_filter(self.fs, [d])  # now usable
        with self.assertRaises(SystemExit):  # never overwritten
            E.backfill_content(d)

    def test_backfill_refused_when_a_covered_file_is_newer(self):
        d = score_dir(self.t / "A", self.fs, "A", self.kw, content=False)
        self._complete_at(d, time.time() - 3600)
        later = time.time()
        os.utime(self.ckpt, (later, later))  # the checkpoint was written after scoring completed
        with self.assertRaisesRegex(SystemExit, "modified after"):
            E.backfill_content(d)
        self.assertFalse((d / "scores" / "CONTENT.json").exists())

    def test_backfill_requires_a_complete_verified_directory(self):
        d = score_dir(self.t / "A", self.fs, "A", self.kw, content=False)
        (d / "scores" / "COMPLETE.json").unlink()
        with self.assertRaises(SystemExit):
            E.backfill_content(d)


LIVE_SCORER = """
import numpy as np
from lfspk.api import CostReport, frame_count
VALUE = {value}
class _P:
    def to_bytes(self):
        return b"p"
class Live:
    name = "live"
    def enroll(self, utterances):
        return _P()
    def update(self, profile, utterance):
        return profile
    def score(self, profile, audio):
        return np.full(frame_count(audio.size), VALUE, np.float32)
    def cost(self):
        return CostReport(params=1, macs_per_audio_second=1.0, update_macs=0.0, profile_bytes=1, reads_parakeet_layers=(), notes="")
def make():
    return Live()
"""


class Review1Test(unittest.TestCase):
    """sol lfspk-W0F-scorecontent-r1: each test fails on r1 and passes on r2."""

    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory(dir="/tmp")
        self.t = Path(self._tmp.name)
        self.cwd = os.getcwd()
        self.path = list(sys.path)
        self.env = dict(os.environ)

    def tearDown(self):
        os.chdir(self.cwd)
        sys.path[:] = self.path
        os.environ.clear()
        os.environ.update(self.env)
        for m in [m for m in sys.modules if m.startswith("w0f_live_")]:
            del sys.modules[m]
        self._tmp.cleanup()

    def _live_module(self, name: str, value: float) -> Path:
        d = self.t / "pkg"
        d.mkdir(exist_ok=True)
        f = d / f"{name}.py"
        f.write_text(LIVE_SCORER.format(value=value))
        if str(d) not in sys.path:
            sys.path.insert(0, str(d))
        return f

    def test_run_scoring_workers_run_the_recorded_code(self):
        # #1: main() has imported the scorer; its source is edited before scoring starts. The workers
        # must run the code the content identity records (fresh spawn workers), not the parent's copy.
        import importlib

        f = self._live_module("w0f_live_a", 0.25)
        importlib.import_module("w0f_live_a")  # what main() does when it names the run
        f.write_text(LIVE_SCORER.format(value=0.75))
        fs = FrozenSet("fake-set", root=X.build_set(self.t / "set"))
        out = self.t / "out"
        E.run_scoring("fake-set", "w0f_live_a:make", {}, "all", 2, out, root=fs.root)
        vals = {float(v[0]) for s in X.SPEAKERS for v in E.load_scores(out / "scores" / f"{s}.npz").values()}
        self.assertEqual(vals, {0.75})
        c = json.loads((out / "scores" / "CONTENT.json").read_text())
        self.assertEqual(dict(c["code"])[str(f)], E._sha256_path(f))

    def test_relative_paths_resolve_in_the_scoring_cwd(self):
        # #2: a relative checkpoint path is resolved where scoring runs, at open time.
        a, b = self.t / "a", self.t / "b"
        for d, w in ((a, b"v1"), (b, b"v2")):
            d.mkdir()
            (d / "ckpt.bin").write_bytes(w)
        os.chdir(a)
        ca = E.content_identity(SPEC, {"checkpoint": "ckpt.bin"})
        os.chdir(b)
        cb = E.content_identity(SPEC, {"checkpoint": "ckpt.bin"})
        self.assertIn(str(a / "ckpt.bin"), dict(ca["loaded"]))
        self.assertIn(str(b / "ckpt.bin"), dict(cb["loaded"]))
        self.assertNotEqual(ca["sha256"], cb["sha256"])

    def test_read_write_opens_are_captured(self):
        # #3: r+b and os.open(O_RDWR) reads are part of the identity.
        p = self.t / "ckpt.bin"
        p.write_bytes(b"weights")
        for mode in ("r+b", "osrdwr"):
            with self.subTest(mode):
                self.assertIn(str(p), dict(E.content_identity(SPEC, {"checkpoint": str(p), "mode": mode})["loaded"]))

    def test_backfill_checks_symlink_chains(self):
        # #4: retargeting a checkpoint symlink to an older file after scoring is refused.
        old = time.time() - 7200
        v1, v2 = self.t / "v1.bin", self.t / "v2.bin"
        v1.write_bytes(b"weights v1")
        v2.write_bytes(b"weights v2")
        link = self.t / "ckpt.bin"
        link.symlink_to(v1)
        for p in (v1, v2):
            os.utime(p, (old, old))
        os.utime(link, (old, old), follow_symlinks=False)
        fs = FrozenSet("fake-set", root=X.build_set(self.t / "set"))
        kw = {"checkpoint": str(link)}
        d = score_dir(self.t / "A", fs, "A", kw, content=False)
        done = time.time()  # after every covered file (code included) was last written
        os.utime(d / "scores" / "COMPLETE.json", (done, done))
        time.sleep(0.05)
        link.unlink()
        link.symlink_to(v2)  # retargeted after scoring; both targets are older than COMPLETE
        with self.assertRaisesRegex(SystemExit, "modified after"):
            E.backfill_content(d)
        os.utime(link, (old, old), follow_symlinks=False)  # an unchanged chain backfills
        self.assertTrue(E.backfill_content(d)["backfilled"])
        self.assertIn(str(link), dict(json.loads((d / "scores" / "CONTENT.json").read_text())["loaded"]))

    def test_import_paths_and_device_environment_preserved(self):
        # #5: the probe imports what scoring imports (the caller's sys.path) and sees the same device env.
        self._live_module("w0f_live_b", 0.5)  # importable only through a sys.path entry of this process
        os.environ["CUDA_VISIBLE_DEVICES"] = "7"
        ci = E.content_identity("w0f_live_b:make", {})
        self.assertIn(str(self.t / "pkg" / "w0f_live_b.py"), dict(ci["code"]))
        self.assertEqual(ci["device_env"], {"CUDA_VISIBLE_DEVICES": "7"})

    def test_failed_warmup_refused(self):
        # #6: an identity whose warm-up failed is not created.
        p = self.t / "ckpt.bin"
        p.write_bytes(b"weights")
        with self.assertRaisesRegex(SystemExit, "warm-up"):
            E.content_identity(SPEC, {"checkpoint": str(p), "fail": "1"})


class Review2Test(Review1Test):
    """sol lfspk-W0F-scorecontent-r2: each test fails on r2 and passes on r3."""

    test_run_scoring_workers_run_the_recorded_code = None  # inherited fixtures only
    test_relative_paths_resolve_in_the_scoring_cwd = None
    test_read_write_opens_are_captured = None
    test_backfill_checks_symlink_chains = None
    test_import_paths_and_device_environment_preserved = None
    test_failed_warmup_refused = None

    def test_probe_imports_exactly_what_the_workers_import(self):
        # #1: a same-named scorer module in the cwd must not shadow the one on the caller's sys.path.
        import importlib

        a = self._live_module("w0f_live_dup", 0.25)  # on sys.path, ahead of everything else
        here = self.t / "cwd"
        here.mkdir()
        (here / "w0f_live_dup.py").write_text(LIVE_SCORER.format(value=0.75))
        os.chdir(here)
        importlib.invalidate_caches()
        ci = E.content_identity("w0f_live_dup:make", {})
        self.assertIn(str(a), dict(ci["code"]))
        self.assertNotIn(str(here / "w0f_live_dup.py"), dict(ci["code"]))
        fs = FrozenSet("fake-set", root=X.build_set(self.t / "set"))
        out = self.t / "out"
        E.run_scoring("fake-set", "w0f_live_dup:make", {}, "all", 2, out, root=fs.root)
        vals = {float(v[0]) for s in X.SPEAKERS for v in E.load_scores(out / "scores" / f"{s}.npz").values()}
        self.assertEqual(vals, {0.25})  # the workers' module, and the one hashed
        self.assertEqual(dict(json.loads((out / "scores" / "CONTENT.json").read_text())["code"])[str(a)], E._sha256_path(a))

    def _tree(self):
        """t/real/weights.bin (the file the kernel opens), t/real/subdir, a decoy
        t/weights.bin beside the links, and t/alias -> real/subdir."""
        (self.t / "real" / "subdir").mkdir(parents=True)
        real = self.t / "real" / "weights.bin"
        real.write_bytes(b"real weights")
        (self.t / "weights.bin").write_bytes(b"decoy beside the links")
        (self.t / "alias").symlink_to(self.t / "real" / "subdir")
        return real

    def test_dotdot_after_a_symlink_is_resolved_by_the_kernel_rule(self):
        # #2: alias/../weights.bin is real/weights.bin, not the weights.bin beside alias.
        real = self._tree()
        os.chdir(self.t)
        ci = E.content_identity(SPEC, {"checkpoint": "alias/../weights.bin"})
        opened = str(self.t / "alias/../weights.bin")
        self.assertEqual(dict(ci["loaded"])[opened], E._sha256_path(real))
        self.assertEqual(ci["resolution"][opened], {"links": [str(self.t / "alias")], "target": str(real)})

    def test_backfill_follows_links_before_dotdot(self):
        # #3: checkpoint.bin -> inner/../weights.bin with inner -> real/subdir reads real/weights.bin;
        # a change to that file after scoring is refused even though the decoy beside it is old.
        real = self._tree()
        (self.t / "inner").symlink_to(self.t / "real" / "subdir")
        ck = self.t / "checkpoint.bin"
        ck.symlink_to("inner/../weights.bin")
        old = time.time() - 7200
        for q in (real, self.t / "weights.bin"):
            os.utime(q, (old, old))
        for q in (ck, self.t / "inner", self.t / "alias"):
            os.utime(q, (old, old), follow_symlinks=False)
        fs = FrozenSet("fake-set", root=X.build_set(self.t / "set"))
        d = score_dir(self.t / "A", fs, "A", {"checkpoint": str(ck)}, content=False)
        done = time.time()
        os.utime(d / "scores" / "COMPLETE.json", (done, done))
        time.sleep(0.05)
        real.write_bytes(b"real weights, changed after scoring")
        with self.assertRaisesRegex(SystemExit, "modified after"):
            E.backfill_content(d)
        self.assertEqual(E.walk(ck), ([str(ck), str(self.t / "inner")], str(real)))


class Review3Test(Review1Test):
    """sol lfspk-W0F-scorecontent-r3: each test fails on r3 and passes on r4."""

    test_run_scoring_workers_run_the_recorded_code = None  # inherited fixtures only
    test_relative_paths_resolve_in_the_scoring_cwd = None
    test_read_write_opens_are_captured = None
    test_backfill_checks_symlink_chains = None
    test_import_paths_and_device_environment_preserved = None
    test_failed_warmup_refused = None

    def test_empty_path_entry_means_the_original_dir_as_under_spawn(self):
        # #1: spawn workers turn the first "" of sys.path into multiprocessing's ORIGINAL_DIR; so must the probe.
        import importlib
        import multiprocessing.process as mpp

        orig, here = self.t / "orig", self.t / "cwd"
        for d, v in ((orig, 0.25), (here, 0.75)):
            d.mkdir()
            (d / "w0f_live_orig.py").write_text(LIVE_SCORER.format(value=v))
        saved = mpp.ORIGINAL_DIR
        try:
            mpp.ORIGINAL_DIR = str(orig)  # where this process started
            sys.path.insert(0, "")
            os.chdir(here)
            importlib.invalidate_caches()
            fs = FrozenSet("fake-set", root=X.build_set(self.t / "set"))
            out = self.t / "out"
            E.run_scoring("fake-set", "w0f_live_orig:make", {}, "all", 2, out, root=fs.root)
        finally:
            mpp.ORIGINAL_DIR = saved
        vals = {float(v[0]) for s in X.SPEAKERS for v in E.load_scores(out / "scores" / f"{s}.npz").values()}
        self.assertEqual(vals, {0.25})
        code = dict(json.loads((out / "scores" / "CONTENT.json").read_text())["code"])
        self.assertIn(str(orig / "w0f_live_orig.py"), code)
        self.assertNotIn(str(here / "w0f_live_orig.py"), code)

    def test_failed_opens_and_impossible_paths_are_not_dependencies(self):
        # #2: broken.bin -> missing/../unread.bin cannot be opened (missing intermediate), nor can
        # file.txt/../unread.bin (non-directory intermediate); a caught failed read adds nothing.
        ck = self.t / "ckpt.bin"
        ck.write_bytes(b"weights")
        (self.t / "unread.bin").write_bytes(b"never read")
        (self.t / "file.txt").write_bytes(b"a regular file")
        (self.t / "broken.bin").symlink_to("missing/../unread.bin")
        for opt in (str(self.t / "broken.bin"), str(self.t / "file.txt") + "/../unread.bin"):
            with self.subTest(opt):
                ci = E.content_identity(SPEC, {"checkpoint": str(ck), "optional": opt})
                self.assertNotIn(opt, dict(ci["loaded"]))
                self.assertNotIn(str(self.t / "unread.bin"), [r["target"] for r in ci["resolution"].values()])
                self.assertIn(str(ck), dict(ci["loaded"]))
        with self.assertRaises(OSError):
            E.walk(self.t / "broken.bin")
        with self.assertRaises(OSError):
            E.walk(str(self.t / "file.txt") + "/../unread.bin")


if __name__ == "__main__":
    unittest.main()
