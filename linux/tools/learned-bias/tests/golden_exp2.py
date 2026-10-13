"""The fixed experiment-2 toy behind tests/golden_exp2.json: two toy runs
(L1, L2) without any experiment-3 flag, on CPU with one thread. Its output
hashes were recorded with the experiment-2 code (commit 9cd286c, torch
2.13.0+cu130) by `python -m tests.golden_exp2 > tests/golden_exp2.json`."""

import contextlib
import hashlib
import io
import json
import sys
import tempfile
from pathlib import Path

import torch

_ROOT = str(Path(__file__).resolve().parents[1])
if _ROOT not in sys.path:
    sys.path.insert(0, _ROOT)

from learned_bias import train  # noqa: E402
from learned_bias.fixtures import synthetic_export, synthetic_shard  # noqa: E402
from learned_bias.joint import JointOutput  # noqa: E402

GOLDEN_TORCH = "2.13.0+cu130"


def content_sha256(path):
    """sha256 of a safetensors file's content: every tensor (name, dtype,
    shape, bytes) in name order, then the metadata as sorted JSON. The file
    bytes themselves are not reproducible across processes: the header's
    metadata order comes from a Rust HashMap."""
    from safetensors import safe_open

    h = hashlib.sha256()
    with safe_open(str(path), framework="np") as f:
        for k in sorted(f.keys()):
            t = f.get_tensor(k)
            h.update(f"{k}|{t.dtype}|{list(t.shape)}|".encode())
            h.update(t.tobytes())
        h.update(json.dumps(f.metadata() or {}, sort_keys=True).encode())
    return h.hexdigest()


def run_golden():
    threads = torch.get_num_threads()
    torch.set_num_threads(1)
    try:
        with tempfile.TemporaryDirectory() as d:
            d = Path(d)
            exp = synthetic_export(d / "export")
            jo = JointOutput.from_export(exp)
            for i in range(3):
                synthetic_shard(d / "prep" / "train" / f"c{i}.0.safetensors", seed=50 + i, utterances=5,
                                session=f"c{i}", joint=jo)
            out = {}
            for v in ("L1", "L2"):
                with contextlib.redirect_stdout(io.StringIO()):
                    train.main(["--variant", v, "--run", f"g-{v}", "--prep", str(d / "prep"),
                                "--out-root", str(d / "train"), "--export", str(exp), "--device", "cpu", "--toy",
                                "--batch", "8", "--epochs", "2"])
                run = d / "train" / f"g-{v}"
                info = json.loads((run / "run.json").read_text())
                info.pop("device")
                info.pop("torch")
                for k in ("prep", "out_root", "export"):  # temporary paths
                    info["args"].pop(k)
                out[v] = {
                    "models": {p.name: content_sha256(p)
                               for p in sorted(run.glob("model-*.safetensors"))},
                    "run_json": hashlib.sha256(json.dumps(info, sort_keys=True).encode()).hexdigest(),
                    "calls": (run / "calls.txt").read_text(),
                }
            return out
    finally:
        torch.set_num_threads(threads)


if __name__ == "__main__":
    json.dump(run_golden(), sys.stdout, indent=1, sort_keys=True)
    print()
