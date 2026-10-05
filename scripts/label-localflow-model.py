#!/usr/bin/env python3
"""Label a copied inference bundle LocalFlow without changing trained weights."""
import hashlib
import json
from pathlib import Path
import sys


def label_bundle(directory):
    directory = Path(directory).resolve()
    manifest_path = directory / "bundle.json"
    manifest = json.loads(manifest_path.read_text())
    if manifest.get("model") not in ("localflow", "parakeet-v2-ternary"):
        raise ValueError("Unexpected model identity")
    files = manifest["files"]
    # Validate before updating metadata hashes. Never bless changed weights.
    for name, digest in files.items():
        relative = Path(name)
        path = directory / relative
        if relative.is_absolute() or ".." in relative.parts or not path.resolve().is_relative_to(directory):
            raise ValueError("Invalid model asset path")
        if hashlib.sha256(path.read_bytes()).hexdigest() != digest:
            raise ValueError("Model asset integrity check failed")
    for name in ("frontend.json", "decoder_joint.json"):
        if name not in files:
            raise ValueError("Missing model metadata")
        path = directory / name
        metadata = json.loads(path.read_text())
        provenance = metadata.setdefault("provenance", {})
        provenance.update(model="localflow", base_model="parakeet-v2-ternary")
        path.write_text(json.dumps(metadata, indent=2) + "\n")
        files[name] = hashlib.sha256(path.read_bytes()).hexdigest()
    manifest.update(model="localflow", display_name="LocalFlow", base_model="parakeet-v2-ternary")
    manifest_path.write_text(json.dumps(manifest, indent=2) + "\n")


if __name__ == "__main__":
    label_bundle(sys.argv[1])
