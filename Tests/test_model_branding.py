import hashlib
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location("model_branding", Path(__file__).resolve().parents[1] / "scripts/label-localflow-model.py")
branding = importlib.util.module_from_spec(spec)
spec.loader.exec_module(branding)

KEA_B_EXPORT = "ec05526ed7aa7c742ee970c09724b1b8ccfaef6eb10f2ff1a11b031e9dfc4995"
KEA_T_EXPORT = "a287e97719c451b785be2cd01ecc861fcaa010ebaa4ff2841783ec78fcd61503"


class ModelBrandingTests(unittest.TestCase):
    def fixture(self, directory):
        assets = {"frontend.json": b'{"provenance":{"export_sha256":"synthetic"}}',
                  "decoder_joint.json": b'{"provenance":{"export_sha256":"synthetic"}}',
                  "weights.bin": b"invented model weights"}
        for name, data in assets.items():
            (directory / name).write_bytes(data)
        manifest = {"model": "localflow", "base_model": "kea-b-prime", "export_sha256": KEA_B_EXPORT, "files": {
            name: hashlib.sha256(data).hexdigest() for name, data in assets.items()}}
        (directory / "bundle.json").write_text(json.dumps(manifest))
        return manifest

    def test_rename_preserves_weights_provenance_and_integrity(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            original = self.fixture(directory)
            branding.label_bundle(directory)
            manifest = json.loads((directory / "bundle.json").read_text())
            self.assertEqual(manifest["model"], "localflow")
            self.assertEqual(manifest["display_name"], "LocalFlow")
            self.assertEqual(manifest["files"]["weights.bin"], original["files"]["weights.bin"])
            self.assertEqual((directory / "weights.bin").read_bytes(), b"invented model weights")
            for name, digest in manifest["files"].items():
                self.assertEqual(hashlib.sha256((directory / name).read_bytes()).hexdigest(), digest)
            provenance = json.loads((directory / "frontend.json").read_text())["provenance"]
            self.assertEqual(provenance["export_sha256"], "synthetic")
            self.assertEqual(provenance["base_model"], "kea-b-0.1")
            self.assertEqual(manifest["base_model"], "kea-b-0.1")
            self.assertEqual(manifest["export_sha256"], KEA_B_EXPORT)
            branding.label_bundle(directory)
            self.assertEqual(json.loads((directory / "bundle.json").read_text()), manifest)

    def test_changed_weights_rejected_without_relabeling(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            original = self.fixture(directory)
            (directory / "weights.bin").write_bytes(b"changed synthetic weights")
            with self.assertRaises(ValueError):
                branding.label_bundle(directory)
            self.assertEqual(json.loads((directory / "bundle.json").read_text()), original)

    def test_other_exports_rejected_without_relabeling(self):
        # The bundled NOTICE describes kea-b-0.1 only, so no other weights may carry its name.
        for export in (KEA_T_EXPORT, None):
            with tempfile.TemporaryDirectory() as temporary:
                directory = Path(temporary)
                manifest = self.fixture(directory)
                if export is None:
                    del manifest["export_sha256"]
                else:
                    manifest["export_sha256"] = export
                (directory / "bundle.json").write_text(json.dumps(manifest))
                with self.assertRaises(ValueError):
                    branding.label_bundle(directory)
                self.assertEqual(json.loads((directory / "bundle.json").read_text()), manifest)

    def test_unsafe_paths_and_unknown_models_rejected(self):
        for name in ("../synthetic", "/synthetic"):
            with tempfile.TemporaryDirectory() as temporary:
                directory = Path(temporary)
                manifest = self.fixture(directory)
                manifest["files"] = {name: "synthetic"}
                (directory / "bundle.json").write_text(json.dumps(manifest))
                with self.assertRaises(ValueError):
                    branding.label_bundle(directory)
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            manifest = self.fixture(directory)
            manifest["model"] = "unrelated model"
            (directory / "bundle.json").write_text(json.dumps(manifest))
            with self.assertRaises(ValueError):
                branding.label_bundle(directory)
