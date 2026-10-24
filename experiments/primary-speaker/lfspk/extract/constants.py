"""Parakeet's own front-end constants (window, mel filterbank), taken from the
checkpoint the harness transcribes with (review implI1-r1 #1).

A restored NeMo model uses the `preprocessor.featurizer.window` and
`preprocessor.featurizer.fb` buffers stored in its checkpoint, so `apply` must
use exactly those values to agree with the hook. They are extracted once into
a small file:

    ./python -m lfspk.extract.constants extract      # reads the .nemo, writes runs/W5/constants/

and loaded, hash-verified, by `load()`.
"""

from __future__ import annotations

import argparse
import hashlib
import io
import json
import tarfile
import time
from pathlib import Path

import numpy as np

from lfspk import paths

OUT = paths.RUNS / "W5" / "constants" / "parakeet-tdt-0.6b-v2-frontend.npz"
# Pinned at extraction (2026-10-22T06:56:22Z) from the .nemo with SHA-256
# d99e39955c9d3d0350d8fb7c75e40c64a2b2eaeb003883d7c941fd2e8747b28c (= W0's ASR cache model_sha256).
SHA256: str | None = "f8254e0d64513739770345a31b576e4b8bf9ff5017d2db9b049f69aaf87916c4"
SOURCE_SHA256 = "d99e39955c9d3d0350d8fb7c75e40c64a2b2eaeb003883d7c941fd2e8747b28c"
KEYS = {"window": "preprocessor.featurizer.window", "fb": "preprocessor.featurizer.fb"}


class _Lazy:
    """Placeholder for anything in the checkpoint pickle other than the tensors we read."""

    def __init__(self, *a, **k):
        pass

    def __call__(self, *a, **k):
        return _Lazy()

    def __setstate__(self, state):
        pass


def _read_buffers(fileobj, keys) -> dict[str, np.ndarray]:
    """Read named float32 tensors from a torch zip checkpoint without loading
    the others: unpickle data.pkl with placeholder storages, then read only the
    storage records the requested tensors use."""
    import collections
    import pickle
    import zipfile

    zf = zipfile.ZipFile(fileobj)
    pkl = next(n for n in zf.namelist() if n.endswith("/data.pkl"))
    prefix = pkl[: -len("data.pkl")]

    class Unpickler(pickle.Unpickler):
        def find_class(self, module, name):
            if (module, name) == ("torch._utils", "_rebuild_tensor_v2"):
                return lambda storage, offset, size, stride, *a: ("tensor", storage, offset, tuple(size), tuple(stride))
            if (module, name) == ("collections", "OrderedDict"):
                return collections.OrderedDict
            if module == "torch" and name.endswith("Storage"):
                return name
            return _Lazy

        def persistent_load(self, pid):
            return tuple(pid)  # ('storage', storage type, key, location, numel)

    state = Unpickler(io.BytesIO(zf.read(pkl))).load()
    out = {}
    for name, key in keys.items():
        kind, storage, offset, size, stride = state[key]
        dtype = storage[1] if isinstance(storage[1], str) else getattr(storage[1], "__name__", str(storage[1]))
        if kind != "tensor" or "Float" not in dtype:
            raise ValueError(f"{key}: expected a float32 tensor, got {dtype}")
        buf = np.frombuffer(zf.read(f"{prefix}data/{storage[2]}"), dtype="<f4")
        n = int(np.prod(size))
        if list(stride) != [int(np.prod(size[i + 1:])) for i in range(len(size))]:
            raise ValueError(f"{key}: not contiguous")
        out[name] = buf[offset: offset + n].reshape(size).copy()
    return out


def extract(nemo: Path = paths.PARAKEET_V2_NEMO, out: Path = OUT) -> dict:
    if out.exists():
        raise FileExistsError(f"{out} exists; constants are extracted once and pinned")
    t0 = time.time()
    if SOURCE_SHA256 is not None:
        h = hashlib.sha256()
        with open(nemo, "rb") as f:
            for chunk in iter(lambda: f.read(1 << 24), b""):
                h.update(chunk)
        if h.hexdigest() != SOURCE_SHA256:
            raise ValueError(f"{nemo} is not the pinned source checkpoint")
    with tarfile.open(nemo) as tar:
        member = next(m for m in tar.getmembers() if m.name.lstrip("./") == "model_weights.ckpt")
        bufs = _read_buffers(tar.extractfile(member), KEYS)
    window, fb = bufs["window"].astype(np.float32), bufs["fb"].astype(np.float32)
    if window.shape != (400,) or fb.reshape(-1, 257).shape != (128, 257):
        raise ValueError(f"unexpected shapes {window.shape} {fb.shape}")
    out.parent.mkdir(parents=True, exist_ok=True)
    h = hashlib.sha256()
    with open(nemo, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 24), b""):
            h.update(chunk)
    nemo_sha = h.hexdigest()
    meta = {"source": str(nemo), "source_sha256": nemo_sha, "keys": KEYS,
            "created_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())}
    np.savez(out, window=window, fb=fb.reshape(128, 257), meta=np.array(json.dumps(meta)))
    sha = hashlib.sha256(out.read_bytes()).hexdigest()
    return {"out": str(out), "sha256": sha, "elapsed_s": round(time.time() - t0, 1), **meta}


def load(path: Path = OUT, sha256: str | None = None) -> tuple[np.ndarray, np.ndarray]:
    """(window [400], fb [128, 257]) float32, verified against the pinned hash."""
    want = sha256 or SHA256
    if want is None:
        raise RuntimeError("Parakeet front-end constants are not pinned yet; run `lfspk.extract.constants extract`")
    raw = Path(path).read_bytes()
    got = hashlib.sha256(raw).hexdigest()
    if got != want:
        raise ValueError(f"{path}: SHA-256 {got} != pinned {want}")
    z = np.load(io.BytesIO(raw), allow_pickle=False)
    return z["window"].astype(np.float32), z["fb"].astype(np.float32)


def check_model(model, expected: tuple[np.ndarray, np.ndarray] | None = None) -> None:
    """Refuse a model whose front-end buffers differ from the constants `apply`
    uses (default: the pinned ones), so the hook and `apply` cannot drift apart
    if the checkpoint changes (review implI1-r2 #1)."""
    pre = getattr(model, "preprocessor", None)
    pre = getattr(pre, "base", pre)  # an installed MaskedPreprocessor wraps the original
    f = getattr(pre, "featurizer", None)
    if f is None:
        raise TypeError("model has no NeMo featurizer")
    w, fb = expected if expected is not None else load()
    mw = f.window.detach().cpu().float().numpy()
    mfb = f.fb.detach().cpu().float().numpy().reshape(128, -1)
    if not (np.array_equal(mw, np.asarray(w, np.float32)) and np.array_equal(mfb, np.asarray(fb, np.float32))):
        raise ValueError("the model's front-end constants differ from the ones apply() uses; refusing")


def available() -> bool:
    return SHA256 is not None and OUT.is_file()


def main(argv=None) -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("cmd", choices=("extract",))
    ap.parse_args(argv)
    print(json.dumps(extract(), indent=1))


if __name__ == "__main__":
    main()
