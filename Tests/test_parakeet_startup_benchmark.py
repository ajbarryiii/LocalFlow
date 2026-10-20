import hashlib
import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
import unittest

spec = importlib.util.spec_from_file_location("startup_benchmark", Path(__file__).resolve().parents[1] / "scripts/benchmark-parakeet-startup.py")
benchmark = importlib.util.module_from_spec(spec)
spec.loader.exec_module(benchmark)


class StartupBenchmarkTests(unittest.TestCase):
    def test_bundle_hash_and_path_validation(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            names = ("frontend.json", "frontend.f32bin", "decoder_joint.json", "decoder_joint.f32bin",
                     "vocabulary.json", "Encoder.mlmodelc/model.mil", "Encoder.mlmodelc/weights/weight.bin")
            files = {}
            for name in names:
                path = directory / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(b"invented test bytes")
                files[name] = hashlib.sha256(path.read_bytes()).hexdigest()
            manifest = {"export_sha256": "a287e97719c451b785be2cd01ecc861fcaa010ebaa4ff2841783ec78fcd61503",
                        "encoder": "C6s8", "layout": "plain", "files": files}
            def write():
                (directory / "bundle.json").write_text(json.dumps(manifest))
            write()
            self.assertEqual(benchmark.verify_bundle(directory), manifest)
            for unsafe in ("../escape", "/absolute"):
                files[unsafe] = "invented"
                write()
                with self.assertRaises(ValueError):
                    benchmark.verify_bundle(directory)
                del files[unsafe]
            del files["frontend.json"]
            write()
            with self.assertRaises(ValueError):
                benchmark.verify_bundle(directory)
            files["frontend.json"] = "0" * 64
            write()
            with self.assertRaises(ValueError):
                benchmark.verify_bundle(directory)

    def test_compile_flags_type_check_the_shared_parakeet_sources(self):
        # The benchmark builds the shared Parakeet sources with its own flags, so
        # they must stay valid for the app's deployment target.
        sdk = subprocess.check_output(["xcrun", "--sdk", "macosx", "--show-sdk-path"], text=True).strip()
        result = subprocess.run(
            ["swiftc", "-parse-as-library", "-typecheck", "-warnings-as-errors", "-sdk", sdk,
             *benchmark.SWIFT_TARGET_FLAGS, *benchmark.swift_sources()],
            capture_output=True, text=True, timeout=300)
        self.assertEqual(result.returncode, 0, result.stderr[-4000:])


if __name__ == "__main__":
    unittest.main()
