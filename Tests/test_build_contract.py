import os
from pathlib import Path
import plistlib
import subprocess
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[1]


def make(*arguments):
    # Run the repository Makefile in isolation from any parent make invocation.
    environment = {key: value for key, value in os.environ.items()
                   if key not in {"MAKEFLAGS", "MFLAGS", "MAKELEVEL", "PARAKEET_BUNDLE_DIR", "ARCH"}}
    return subprocess.run(["make", "--no-print-directory", "-C", str(REPO), *arguments],
                          env=environment, capture_output=True, text=True, timeout=120)


class ReleasePreflightTests(unittest.TestCase):
    def test_fails_without_a_model_bundle_directory(self):
        result = make("release-preflight", "PARAKEET_BUNDLE_DIR=")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("PARAKEET_BUNDLE_DIR", result.stderr)

    def test_fails_when_the_directory_has_no_bundle_manifest(self):
        with tempfile.TemporaryDirectory() as temporary:
            result = make("release-preflight", f"PARAKEET_BUNDLE_DIR={temporary}")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("bundle.json", result.stderr)

    def test_passes_with_a_bundle_manifest(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary) / "invented model bundle"
            directory.mkdir()
            (directory / "bundle.json").write_text('{"model": "synthetic", "files": {}}')
            result = make("release-preflight", f"PARAKEET_BUNDLE_DIR={directory}")
        self.assertEqual(result.returncode, 0, result.stderr)


class AppBuildTargetTests(unittest.TestCase):
    def dry_run_build(self, arch):
        with tempfile.TemporaryDirectory() as temporary:
            return make("-B", "-n", "all", f"ARCH={arch}", f"BUILD_DIR={temporary}", "PARAKEET_BUNDLE_DIR=")

    def test_rejects_architectures_other_than_apple_silicon(self):
        for arch in ("x86_64", "universal"):
            with self.subTest(arch=arch):
                result = self.dry_run_build(arch)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("Apple Silicon only", result.stderr)

    def test_compiles_for_the_minimum_system_version_in_info_plist(self):
        with open(REPO / "Info.plist", "rb") as file:
            minimum = plistlib.load(file)["LSMinimumSystemVersion"]
        result = self.dry_run_build("arm64")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(f"-target arm64-apple-macosx{minimum} ", result.stdout)


if __name__ == "__main__":
    unittest.main()
