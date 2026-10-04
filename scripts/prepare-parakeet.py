#!/usr/bin/env python3
"""Convert a verified final export with the existing wilderness-labs-stt toolchain.

Run with its pinned Mac Python through ios/macguard. All output stays in the
upstream artifact area; the FreeFlow build copies only the inference bundle.
"""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import sys
from types import SimpleNamespace


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--upstream", type=Path, required=True)
    parser.add_argument("--export", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    ios = args.upstream / "finetune/parakeet-ternary/ios"
    sys.path.insert(0, str(ios))
    import artifacts
    import models
    import native
    import reference
    from mil import build, weights

    export = args.export.resolve()
    output = artifacts.check(args.output)
    source = reference.ExportSource(export)  # Verifies export.safetensors SHA-256.
    export_sha = source.manifest["sha256"]
    if export_sha != "a287e97719c451b785be2cd01ecc861fcaa010ebaa4ff2841783ec78fcd61503":
        raise ValueError("This integration requires the completed 250000-step main export; refusing other weights")
    # Override only this process's benchmark source lookup. Never replace the
    # pilot files or publish benchmark eligibility records for the final model.
    defaults = models._defaults()
    models._defaults = lambda: {**defaults, "mp2": export}
    original_path = weights.default_path
    weights.default_path = lambda name: export if name == "mp2" else original_path(name)
    native.cmd_frontend(SimpleNamespace(model="mp2", out=str(output)))
    native.cmd_weights(SimpleNamespace(model="mp2", out=str(output)))
    manifest = build.build_encoder(
        "mp2", "C6s8", "multi", output / "conversion", plan=False,
        tag="-freeflow", precision="fp16", layout="plain",
    )
    shutil.copytree(manifest["paths"]["mlmodelc"], output / "Encoder.mlmodelc", dirs_exist_ok=True)
    # NeMo's vocab.txt is the legacy WordPiece view and omits <unk>.
    # The SentencePiece vocabulary preserves all 1024 trained token IDs.
    pieces = [line.split("\t")[0] for line in (export / "tokenizer/tokenizer.vocab").read_text().splitlines()]
    if len(pieces) != 1024:
        raise ValueError("Expected 1024 SentencePiece vocabulary entries")
    (output / "vocabulary.json").write_text(json.dumps(dict(enumerate(pieces)), ensure_ascii=False))
    for stem in ("frontend", "decoder_joint"):
        path = output / f"{stem}.json"
        data = json.loads(path.read_text())
        data["provenance"] = {"model": "parakeet-v2-ternary", "export_sha256": export_sha}
        path.write_text(json.dumps(data, indent=2) + "\n")
    files = ["frontend.json", "frontend.f32bin", "decoder_joint.json",
             "decoder_joint.f32bin", "vocabulary.json"]
    files += [str(p.relative_to(output)) for p in sorted((output / "Encoder.mlmodelc").rglob("*")) if p.is_file()]
    bundle = {
        "model": "parakeet-v2-ternary", "training_step": 250000,
        "export_sha256": export_sha, "encoder": "C6s8", "layout": "plain",
        "compute_units": "cpuAndNeuralEngine", "decoder": "native-fp32",
        "buckets_seconds": [2, 4, 8, 15], "sample_rate": 16000,
        "files": {name: hashlib.sha256((output / name).read_bytes()).hexdigest() for name in files},
    }
    (output / "bundle.json").write_text(json.dumps(bundle, indent=2) + "\n")
    print(json.dumps({"export_sha256": export_sha, "bundle_files": len(files)}))


if __name__ == "__main__":
    main()
