"""Audio helpers for W1: loading, 10 ms frame energies and an adaptive energy
speech gate. The gate is a crude, deterministic speech-activity detector used
to place test segments and scorer windows; it is not a VAD contribution."""

from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path

import numpy as np

from ..api import FRAME_SAMPLES, SAMPLE_RATE, frame_count


def load(path: Path) -> np.ndarray:
    import soundfile as sf

    audio, sr = sf.read(str(path), dtype="float32", always_2d=False)
    if sr != SAMPLE_RATE or audio.ndim != 1:
        raise ValueError(f"{path}: expected 16 kHz mono, got {sr} Hz, shape {audio.shape}")
    return np.clip(audio, -1.0, 1.0).astype(np.float32, copy=False)


def frame_energy_db(audio: np.ndarray) -> np.ndarray:
    """Mean-square energy in dBFS per 10 ms frame (contract framing: a final
    partial frame is averaged over the samples it has)."""
    n = frame_count(audio.size)
    if n == 0:
        return np.zeros(0, np.float32)
    padded = np.zeros(n * FRAME_SAMPLES, np.float64)
    padded[:audio.size] = audio
    sq = (padded ** 2).reshape(n, FRAME_SAMPLES).sum(axis=1)
    counts = np.full(n, FRAME_SAMPLES, np.float64)
    counts[-1] = audio.size - (n - 1) * FRAME_SAMPLES
    return (10.0 * np.log10(sq / counts + 1e-10)).astype(np.float32)


@dataclass(frozen=True)
class GateConfig:
    floor_percentile: float = 10.0
    margin_db: float = 10.0  # above the noise floor
    range_db: float = 40.0  # within this many dB of the 95th percentile
    peak_gap_db: float | None = 6.0  # the threshold never exceeds p95 minus this (None: no cap)
    absolute_db: float = -70.0  # never speech below this
    hangover: int = 3  # frames of dilation on each side


def speech_gate(energy_db: np.ndarray, cfg: GateConfig = GateConfig()) -> np.ndarray:
    """Boolean speech mask per frame from frame energies (dB).

    threshold = max(absolute_db, min(max(floor + margin_db, p95 - range_db),
    p95 - peak_gap_db)). The cap at p95 - peak_gap_db keeps a recording that is
    speech throughout (no pause to estimate the floor from) from being gated
    away; the price is that a recording of uniform noise is marked as speech.
    An energy gate cannot tell those two apart."""
    if energy_db.size == 0:
        return np.zeros(0, bool)
    floor = np.percentile(energy_db, cfg.floor_percentile)
    peak = np.percentile(energy_db, 95.0)
    cap = np.inf if cfg.peak_gap_db is None else peak - cfg.peak_gap_db
    thr = max(cfg.absolute_db, min(max(floor + cfg.margin_db, peak - cfg.range_db), cap))
    mask = energy_db > thr
    if cfg.hangover > 0 and mask.any():
        h = cfg.hangover
        full = np.convolve(mask.astype(float), np.ones(2 * h + 1), mode="full")  # length n + 2h
        mask = full[h:h + mask.size] > 0
    return mask


def noise_floor_db(energy_db: np.ndarray, cfg: GateConfig = GateConfig()) -> float:
    return float(np.percentile(energy_db, cfg.floor_percentile)) if energy_db.size else -100.0
