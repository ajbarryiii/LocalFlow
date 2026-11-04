#!/usr/bin/env python3
"""Build LocalFlow's kea-b-0.1 bundle with the wilderness-labs-stt 1-bit Core ML converter.

Run with the upstream pinned Mac Python through ios/macguard. All output stays in the
upstream artifact area; the LocalFlow build copies only the inference bundle.
"""
import argparse
import importlib.util
import json
from pathlib import Path
import sys

REPO = Path(__file__).resolve().parents[1]
# Kea-B' (relabel stage 4 run b100-main): its parakeet-binary-v1 export.
EXPORT_SHA256 = "ec05526ed7aa7c742ee970c09724b1b8ccfaef6eb10f2ff1a11b031e9dfc4995"
# 1-bit codes as a uint1 lookup table with FP16 per-row scales; only the
# 15-second function, the one the app loads.
ENCODER = "B1Q"
BUCKETS = (15,)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--upstream", type=Path, required=True)
    parser.add_argument("--export", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    export = args.export.resolve()
    # Refuse other weights before converting anything. The converter then checks
    # export.safetensors and the tokenizer files against this manifest's hashes.
    if json.loads((export / "manifest.json").read_text()).get("sha256") != EXPORT_SHA256:
        raise ValueError("This integration requires the kea-b-0.1 export; refusing other weights")
    sys.path.insert(0, str(args.upstream / "finetune/parakeet-binary-coreml"))
    import prepare_bundle

    record = prepare_bundle.build(ENCODER, args.output, export, export / "tokenizer", BUCKETS)
    spec = importlib.util.spec_from_file_location("branding", REPO / "scripts/label-localflow-model.py")
    branding = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(branding)
    branding.label_bundle(record["bundle"])
    print(json.dumps({"export_sha256": record["export"]["sha256"], "encoder": record["arm"],
                      "bundle_bytes": record["bundle_bytes"]}))


if __name__ == "__main__":
    main()
