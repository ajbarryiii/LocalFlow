"""Room impulse responses: normalisation, the simulated room bank, distance estimates.

Own bank (DESIGN.md section 3): shoebox rooms simulated with pyroomacoustics
(image method), one laptop microphone per room and sources at roles:
  target_builtin  0.25-0.60 m  (user at a laptop)
  target_headset  0.02-0.05 m  (close-talking boom)
  laptop_speaker  0.08-0.25 m  (call audio from the laptop's speakers)
  far_0..far_5    stratified over 1-5 m (other people, a TV)
Rooms are generated per split from split-specific seeds, so splits never share a
room.
"""

from __future__ import annotations

from typing import Any

import numpy as np

from ..api import SAMPLE_RATE
from .util import rng_for

SPEED_OF_SOUND = 343.0
MAX_RIR_SAMPLES = SAMPLE_RATE  # 1.0 s
PRE_DIRECT_SAMPLES = 16  # keep 1 ms before the direct path
FAR_BANDS = ((1.0, 1.7), (1.7, 2.4), (2.4, 3.1), (3.1, 3.8), (3.8, 4.5), (4.5, 5.0))
BANK_SIZES = {"train": 1200, "dev": 150, "test": 150}


def direct_index(h: np.ndarray) -> int:
    """First sample reaching half the absolute peak: the direct path, robust to a
    later reflection that happens to be stronger."""
    a = np.abs(h)
    return int(np.flatnonzero(a >= 0.5 * a.max())[0])


def normalise_rir(h: np.ndarray) -> np.ndarray:
    """Delay-normalise (direct path at sample PRE_DIRECT_SAMPLES or earlier), cut the
    tail where the Schroeder decay reaches -60 dB (at most 1 s), unit direct peak."""
    h = np.asarray(h, dtype=np.float64).ravel()
    if h.size == 0 or not np.any(h):
        raise ValueError("empty RIR")
    d = direct_index(h)
    h = h[max(0, d - PRE_DIRECT_SAMPLES) :]
    edc = np.cumsum((h**2)[::-1])[::-1]
    edc_db = 10 * np.log10(edc / edc[0] + 1e-30)
    below = np.flatnonzero(edc_db <= -60.0)
    end = int(below[0]) if below.size else h.size
    h = h[: min(end, MAX_RIR_SAMPLES)]
    peak = np.abs(h[: PRE_DIRECT_SAMPLES + 1]).max()
    return (h / (peak if peak > 0 else np.abs(h).max())).astype(np.float32)


def distance_from_delay(h: np.ndarray, fs: int = SAMPLE_RATE) -> float:
    """Source-receiver distance implied by the direct-path delay. Valid for
    simulated RIRs whose time origin is the emission (OpenSLR 26 image method)."""
    return direct_index(np.asarray(h)) / fs * SPEED_OF_SOUND


def drr_db(h: np.ndarray, window: int = 40) -> float:
    """Direct-to-reverberant ratio with a +-2.5 ms direct window (normalised RIR)."""
    h = np.asarray(h, dtype=np.float64)
    d = direct_index(h)
    lo, hi = max(0, d - window), d + window
    direct = np.sum(h[lo:hi] ** 2)
    rev = np.sum(h[hi:] ** 2) + np.sum(h[:lo] ** 2)
    return float(10 * np.log10(direct / max(rev, 1e-30)))


def _place_near(rng: np.random.Generator, mic: np.ndarray, dims: np.ndarray, r: float, z_lo: float, z_hi: float) -> np.ndarray:
    for _ in range(200):
        az = rng.uniform(0, 2 * np.pi)
        dz = rng.uniform(z_lo, z_hi)
        horiz = np.sqrt(max(r**2 - dz**2, 1e-6))
        p = mic + np.array([horiz * np.cos(az), horiz * np.sin(az), dz])
        if np.all(p > 0.1) and np.all(p < dims - 0.1):
            return p
    raise RuntimeError("could not place a near source")


def _place_far(rng: np.random.Generator, mic: np.ndarray, dims: np.ndarray, lo: float, hi: float) -> tuple[np.ndarray, float]:
    """A talker or loudspeaker at 1.1-1.8 m height, distance in [lo, hi] if the
    room allows it, else as far as the room allows (the achieved distance is
    recorded)."""
    best, best_d = None, -1.0
    for _ in range(400):
        p = np.array([rng.uniform(0.3, dims[0] - 0.3), rng.uniform(0.3, dims[1] - 0.3), rng.uniform(1.1, min(1.8, dims[2] - 0.2))])
        d = float(np.linalg.norm(p - mic))
        if lo <= d <= hi:
            return p, d
        if d > best_d and d <= hi:
            best, best_d = p, d
    if best is None:
        raise RuntimeError("could not place a far source")
    return best, best_d


def simulate_room(split: str, index: int) -> dict[str, Any]:
    """One bank room: geometry, T60 and normalised RIRs per role."""
    import pyroomacoustics as pra

    rng = rng_for("room-bank", split, index)
    dims = np.array([rng.uniform(3.0, 9.0), rng.uniform(2.5, 7.0), rng.uniform(2.4, 3.3)])
    t60 = float(rng.uniform(0.2, 0.8))
    mic = np.array([rng.uniform(0.6, dims[0] - 0.6), rng.uniform(0.6, dims[1] - 0.6), rng.uniform(0.7, 1.1)])
    roles: dict[str, tuple[np.ndarray, float]] = {}
    r = float(rng.uniform(0.25, 0.60))
    roles["target_builtin"] = (_place_near(rng, mic, dims, r, 0.1, min(0.4, r * 0.9)), r)
    r = float(rng.uniform(0.02, 0.05))
    roles["target_headset"] = (_place_near(rng, mic, dims, r, -0.5 * r, 0.5 * r), r)
    r = float(rng.uniform(0.08, 0.25))
    roles["laptop_speaker"] = (_place_near(rng, mic, dims, r, -0.05, 0.02), r)
    for k, (lo, hi) in enumerate(FAR_BANDS):
        roles[f"far_{k}"] = _place_far(rng, mic, dims, lo, hi)
    e_abs, max_order = pra.inverse_sabine(t60, dims)
    names = list(roles)
    rirs = {}
    for name in names:  # one source per simulation keeps memory near 200 MB
        room = pra.ShoeBox(dims, fs=SAMPLE_RATE, materials=pra.Material(e_abs), max_order=max_order, air_absorption=True)
        room.add_microphone(mic)
        room.add_source(roles[name][0])
        room.compute_rir()
        rirs[name] = normalise_rir(np.asarray(room.rir[0][0]))
        del room
    return {
        "split": split,
        "index": index,
        "dims": dims.tolist(),
        "t60": t60,
        "mic": mic.tolist(),
        "distance": {name: float(roles[name][1]) for name in names},
        "drr_db": {name: drr_db(rirs[name]) for name in names},
        "rirs": rirs,
    }
