"""Small shared helpers: stable seeding, hashing, audio IO, levels and filters."""

from __future__ import annotations

import hashlib
import json
from pathlib import Path
from typing import Any

import numpy as np
import soundfile as sf
from scipy import signal

from ..api import FRAME_SAMPLES, SAMPLE_RATE, frame_count

EPS = 1e-12


def stable_int(*keys: Any) -> int:
    """A 128-bit integer from the keys, identical across processes and machines."""
    text = "\x1f".join(str(k) for k in keys)
    return int.from_bytes(hashlib.sha256(text.encode("utf-8")).digest()[:16], "little")


def rng_for(*keys: Any) -> np.random.Generator:
    """A numpy Generator seeded only by the keys (never by Python's hash())."""
    return np.random.Generator(np.random.PCG64(np.random.SeedSequence(stable_int(*keys))))


def hash_bucket(key: str, buckets: int = 100) -> int:
    return stable_int("bucket", key) % buckets


def split_by_hash(key: str) -> str:
    """Three-way split of an auxiliary-corpus unit: 10 % test, 10 % dev, 80 % train."""
    b = hash_bucket(key)
    return "test" if b < 10 else "dev" if b < 20 else "train"


def sha256_file(path: Path, chunk: int = 1 << 20) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        while block := f.read(chunk):
            h.update(block)
    return h.hexdigest()


def sha256_json(obj: Any) -> str:
    return hashlib.sha256(json.dumps(obj, sort_keys=True, separators=(",", ":")).encode()).hexdigest()


# --- audio IO -----------------------------------------------------------------


def load_audio(path: Path | str, start: int = 0, frames: int = -1, channel: int = 0) -> np.ndarray:
    """Mono float32 at 16 kHz. Multi-channel files return `channel`."""
    with sf.SoundFile(str(path)) as f:
        sr = f.samplerate
        if start:
            f.seek(start)
        x = f.read(frames=frames, dtype="float32", always_2d=True)
    x = x[:, min(channel, x.shape[1] - 1)]
    if sr != SAMPLE_RATE:
        g = np.gcd(sr, SAMPLE_RATE)
        x = signal.resample_poly(x, SAMPLE_RATE // g, sr // g).astype(np.float32)
    return np.ascontiguousarray(x, dtype=np.float32)


def audio_info(path: Path | str) -> tuple[int, int, int]:
    """(samplerate, frames, channels) without decoding."""
    i = sf.info(str(path))
    return i.samplerate, i.frames, i.channels


# --- levels -------------------------------------------------------------------


def frame_power(x: np.ndarray) -> np.ndarray:
    """Mean square per 10 ms frame; a final partial frame averages its own samples."""
    n = frame_count(x.size)
    if n == 0:
        return np.zeros(0, dtype=np.float64)
    pad = n * FRAME_SAMPLES - x.size
    sq = np.square(x.astype(np.float64))
    sums = np.add.reduceat(sq, np.arange(0, x.size, FRAME_SAMPLES)) if x.size else np.zeros(0)
    counts = np.full(n, FRAME_SAMPLES, dtype=np.float64)
    if pad:
        counts[-1] = FRAME_SAMPLES - pad
    return sums / counts


def db(p: np.ndarray | float) -> np.ndarray | float:
    return 10.0 * np.log10(np.asarray(p, dtype=np.float64) + EPS)


def active_level_db(x: np.ndarray, active: np.ndarray) -> float:
    """10 log10 of the mean square of x over the active frames (sample-weighted)."""
    n = frame_count(x.size)
    if active.size != n:
        raise ValueError(f"activity has {active.size} frames, audio {n}")
    if not active.any():
        raise ValueError("no active frames")
    mask = np.repeat(active, FRAME_SAMPLES)[: x.size]
    return float(db(np.mean(np.square(x[mask].astype(np.float64)))))


def mean_level_db(x: np.ndarray) -> float:
    return float(db(np.mean(np.square(x.astype(np.float64))))) if x.size else float(db(0.0))


def to_frames(samples: int) -> int:
    """Round a sample count down to whole frames, in frames."""
    return samples // FRAME_SAMPLES


def seconds_to_frames(rng: np.random.Generator, lo: float, hi: float) -> int:
    """A uniform duration in [lo, hi] seconds, rounded to whole 10 ms frames."""
    return int(round(rng.uniform(lo, hi) * 100))


# --- filters ------------------------------------------------------------------


def biquad_peaking(f0: float, gain_db: float, q: float, fs: int = SAMPLE_RATE) -> np.ndarray:
    """RBJ cookbook peaking EQ as one SOS row."""
    a = 10 ** (gain_db / 40)
    w0 = 2 * np.pi * f0 / fs
    alpha = np.sin(w0) / (2 * q)
    b = [1 + alpha * a, -2 * np.cos(w0), 1 - alpha * a]
    den = [1 + alpha / a, -2 * np.cos(w0), 1 - alpha / a]
    return np.array([[*(np.array(b) / den[0]), 1.0, den[1] / den[0], den[2] / den[0]]])


def biquad_shelf(f0: float, gain_db: float, high: bool, fs: int = SAMPLE_RATE, s: float = 1.0) -> np.ndarray:
    """RBJ cookbook low or high shelf as one SOS row."""
    a = 10 ** (gain_db / 40)
    w0 = 2 * np.pi * f0 / fs
    cw, sw = np.cos(w0), np.sin(w0)
    alpha = sw / 2 * np.sqrt((a + 1 / a) * (1 / s - 1) + 2)
    sq = 2 * np.sqrt(a) * alpha
    if high:
        b = [a * ((a + 1) + (a - 1) * cw + sq), -2 * a * ((a - 1) + (a + 1) * cw), a * ((a + 1) + (a - 1) * cw - sq)]
        den = [(a + 1) - (a - 1) * cw + sq, 2 * ((a - 1) - (a + 1) * cw), (a + 1) - (a - 1) * cw - sq]
    else:
        b = [a * ((a + 1) - (a - 1) * cw + sq), 2 * a * ((a - 1) - (a + 1) * cw), a * ((a + 1) - (a - 1) * cw - sq)]
        den = [(a + 1) + (a - 1) * cw + sq, -2 * ((a - 1) + (a + 1) * cw), (a + 1) + (a - 1) * cw - sq]
    return np.array([[*(np.array(b) / den[0]), 1.0, den[1] / den[0], den[2] / den[0]]])


def butter(order: int, fc: float | tuple[float, float], btype: str, fs: int = SAMPLE_RATE) -> np.ndarray:
    return signal.butter(order, fc, btype=btype, fs=fs, output="sos")


def sosfilt(sos: np.ndarray, x: np.ndarray) -> np.ndarray:
    if sos.size == 0 or x.size == 0:
        return x.astype(np.float32, copy=True)
    return signal.sosfilt(sos, x.astype(np.float64)).astype(np.float32)


def pink_noise(rng: np.random.Generator, n: int) -> np.ndarray:
    """Unit-RMS pink (1/f power) noise of n samples."""
    if n == 0:
        return np.zeros(0, dtype=np.float32)
    white = rng.standard_normal(n)
    spec = np.fft.rfft(white)
    f = np.fft.rfftfreq(n, 1 / SAMPLE_RATE)
    f[0] = f[1] if n > 1 else 1.0
    spec /= np.sqrt(f / 20.0).clip(min=1.0)  # flat below 20 Hz
    y = np.fft.irfft(spec, n)
    y /= np.sqrt(np.mean(y**2)) + EPS
    return y.astype(np.float32)


def convolve(x: np.ndarray, h: np.ndarray, length: int | None = None) -> np.ndarray:
    """Linear convolution truncated to `length` (default len(x))."""
    n = x.size if length is None else length
    if x.size == 0 or h.size == 0:
        return np.zeros(n, dtype=np.float32)
    y = signal.oaconvolve(x.astype(np.float64), h.astype(np.float64))[:n]
    if y.size < n:
        y = np.pad(y, (0, n - y.size))
    return y.astype(np.float32)
