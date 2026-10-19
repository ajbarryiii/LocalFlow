import contextlib
import importlib.util
import io
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location(
    "shared_vectors", Path(__file__).resolve().parents[1] / "scripts/check-shared-vectors.py")
shared_vectors = importlib.util.module_from_spec(spec)
spec.loader.exec_module(shared_vectors)


class SharedVectorsTests(unittest.TestCase):
    def repository(self, directory, files):
        (directory / "linux/testdata").mkdir(parents=True)
        for name in ("alpha-vectors.json", "beta-vectors.json"):
            (directory / "linux/testdata" / name).write_text('{"version": 1}')
        for path, text in files.items():
            (directory / path).parent.mkdir(parents=True, exist_ok=True)
            (directory / path).write_text(text)
        return directory

    def run_check(self, directory):
        stderr = io.StringIO()
        with contextlib.redirect_stderr(stderr):
            status = shared_vectors.main(["check-shared-vectors.py", str(directory)])
        return status, stderr.getvalue()

    def test_passes_when_both_suites_reference_every_file(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = self.repository(Path(temporary), {
                "Tests/AlphaTests.swift": "linux/testdata/alpha-vectors.json",
                "Tests/BetaTests.swift": "beta-vectors.json",
                "linux/crates/a/tests/vectors.rs": "alpha-vectors.json beta-vectors.json",
            })
            self.assertEqual(self.run_check(directory), (0, ""))

    def test_names_each_file_and_the_suite_that_misses_it(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = self.repository(Path(temporary), {
                "Tests/AlphaTests.swift": "alpha-vectors.json",
                "linux/crates/a/tests/vectors.rs": "alpha-vectors.json",
            })
            status, message = self.run_check(directory)
            self.assertEqual(status, 1)
            self.assertIn("linux/testdata/beta-vectors.json is not referenced from Tests/ or linux/crates/", message)
            self.assertNotIn("alpha-vectors.json", message)

    def test_one_suite_alone_is_not_enough(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = self.repository(Path(temporary), {
                "Tests/Tests.swift": "alpha-vectors.json beta-vectors.json",
                "linux/crates/a/tests/vectors.rs": "alpha-vectors.json",
            })
            status, message = self.run_check(directory)
            self.assertEqual(status, 1)
            self.assertIn("beta-vectors.json is not referenced from linux/crates/;", message)

    def test_build_output_does_not_count_as_a_consumer(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = self.repository(Path(temporary), {
                "Tests/Tests.swift": "alpha-vectors.json beta-vectors.json",
                "linux/crates/a/tests/vectors.rs": "alpha-vectors.json",
                "linux/crates/a/target/debug/build.log": "beta-vectors.json",
            })
            self.assertEqual(self.run_check(directory)[0], 1)


if __name__ == "__main__":
    unittest.main()
