"""Frame-level signal helpers shared by the renders, the tuning stream and the audit.

Frames are the contract's 10 ms frames (160 samples); frame i covers samples
[160 i, 160 (i + 1)) and a final partial frame counts (lfspk.api.frame_count).
"""

from __future__ import annotations

import hashlib
import json

import numpy as np

from lfspk.api import FRAME_SAMPLES, frame_count

MIN_ACTIVE_FRAMES = 50  # W0's rule: an interferer contributes at least 0.5 s of speech


def frame_power(x: np.ndarray) -> np.ndarray:
    """Mean power per contract frame (float64), the final partial frame over its own samples."""
    x = np.asarray(x, dtype=np.float64)
    n = frame_count(len(x))
    if n == 0:
        return np.zeros(0)
    pad = n * FRAME_SAMPLES - len(x)
    sq = np.concatenate([x * x, np.zeros(pad)]).reshape(n, FRAME_SAMPLES)
    counts = np.full(n, FRAME_SAMPLES, dtype=np.float64)
    counts[-1] = FRAME_SAMPLES - pad
    return sq.sum(axis=1) / counts


def pact(x: np.ndarray, active: np.ndarray) -> float:
    """Mean power of x over the samples of the frames where `active` is true (0 if none)."""
    x = np.asarray(x, dtype=np.float64)
    a = np.asarray(active, dtype=bool)
    n = frame_count(len(x))
    if a.shape != (n,):
        raise ValueError(f"activity has {a.shape} frames, signal has {n}")
    if not a.any():
        return 0.0
    mask = np.repeat(a, FRAME_SAMPLES)[: len(x)]
    return float(np.mean(x[mask] ** 2))


def first_active(active: np.ndarray) -> int:
    idx = np.flatnonzero(np.asarray(active, dtype=bool))
    if idx.size == 0:
        raise ValueError("no active frame")
    return int(idx[0])


def shift_samples(x: np.ndarray, shift: int, n: int) -> np.ndarray:
    """out[t + shift] = x[t] for 0 <= t + shift < n; zeros elsewhere."""
    x = np.asarray(x)
    out = np.zeros(n, dtype=np.float32)
    lo, hi = max(0, shift), min(n, shift + len(x))
    if hi > lo:
        out[lo:hi] = x[lo - shift: hi - shift]
    return out


def shift_frames(a: np.ndarray, shift: int, n: int) -> np.ndarray:
    a = np.asarray(a, dtype=bool)
    out = np.zeros(n, dtype=bool)
    lo, hi = max(0, shift), min(n, shift + len(a))
    if hi > lo:
        out[lo:hi] = a[lo - shift: hi - shift]
    return out


def db(p: float) -> float:
    return float(10.0 * np.log10(p))


def arrays_digest(d: dict) -> str:
    """SHA-256 over every array's name, dtype, shape and bytes, in sorted key order."""
    h = hashlib.sha256()
    for k in sorted(d):
        v = np.asarray(d[k])
        if v.dtype.kind in "US":
            b = str(v).encode()
        else:
            b = np.ascontiguousarray(v).tobytes()
        h.update(f"{k}|{v.dtype.str}|{v.shape}|".encode())
        h.update(b)
    return h.hexdigest()


def json_sha256(obj) -> str:
    return hashlib.sha256(json.dumps(obj, sort_keys=True).encode()).hexdigest()


__all__ = ["MIN_ACTIVE_FRAMES", "frame_power", "pact", "first_active", "shift_samples", "shift_frames", "db",
           "arrays_digest", "json_sha256"]
