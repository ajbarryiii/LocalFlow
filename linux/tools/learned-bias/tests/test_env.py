import contextlib
import io
import os
import tempfile
import unittest
from pathlib import Path
from unittest import mock

# Importable both as `tests.<module>` (-t) and as a top-level module (-s only).
_ROOT = str(__import__("pathlib").Path(__file__).resolve().parents[1])  # linux/tools/learned-bias
if _ROOT not in __import__("sys").path:
    __import__("sys").path.insert(0, _ROOT)

from learned_bias import env, gpu
from learned_bias.devcheck import default_results

PACKAGE = Path(_ROOT)
UNSET = {"LF_EXP2_ROOT": "", "LF_EXPORT": "", "LF_GPU_LOCK": ""}


class EnvTests(unittest.TestCase):
    def test_no_machine_paths_in_the_package(self):
        # AGENTS.md: no identifying filesystem paths in the repository.
        needles = ["/" + d + "/" for d in ("mnt", "home", "Users")]  # built so this file passes
        for p in sorted(PACKAGE.rglob("*.py")):
            text = p.read_text()
            for needle in needles:
                self.assertNotIn(needle, text, f"{p.relative_to(PACKAGE)} contains {needle!r}")

    def test_locations_fail_clearly_when_unset(self):
        with mock.patch.dict(os.environ, UNSET):
            for fn, var in ((env.exp2_root, "LF_EXP2_ROOT"), (env.export_path, "LF_EXPORT"),
                            (env.gpu_lock, "LF_GPU_LOCK"), (default_results, "LF_EXP2_ROOT")):
                with self.assertRaises(env.ConfigError) as cm:
                    fn()
                self.assertIn(var, str(cm.exception))
            with self.assertRaises(env.ConfigError):
                gpu.acquire()
        self.assertEqual(env.export_path("/x/export"), "/x/export")
        self.assertEqual(env.gpu_lock("/x/lock"), "/x/lock")
        with mock.patch.dict(os.environ, {"LF_EXP2_ROOT": "/w", "LF_EXPORT": "/e", "LF_GPU_LOCK": "/l"}):
            self.assertEqual((env.exp2_root(), env.export_path(), env.gpu_lock()), (Path("/w"), "/e", "/l"))
            self.assertEqual(default_results(), "/w/eval/{run}/results.json")

    def test_training_refuses_without_locations(self):
        from learned_bias import train

        with tempfile.TemporaryDirectory() as d, mock.patch.dict(os.environ, UNSET):
            base = ["--variant", "L1", "--run", "r", "--toy", "--device", "cpu"]
            cases = {
                "LF_EXPORT": base + ["--prep", d, "--out-root", d],
                "LF_EXP2_ROOT": base + ["--export", d],
                "LF_GPU_LOCK": ["--variant", "L1", "--run", "r", "--toy", "--device", "cuda", "--export", d,
                                "--prep", d, "--out-root", d],
            }
            for var, args in cases.items():
                with self.assertRaises(SystemExit) as cm, contextlib.redirect_stdout(io.StringIO()):
                    train.main(args)
                self.assertIn(var, str(cm.exception))


if __name__ == "__main__":
    unittest.main()
