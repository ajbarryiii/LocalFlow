"""W2-simplemix: a two-speaker additive mixture for the frame-level probe ONLY
(DESIGN 6.1). Not a benchmark scenario: no rooms, noise or devices. Replaced by
W0's mixing API when it exists; results always say which mixtures they used.
"""

from __future__ import annotations

from dataclasses import dataclass

import numpy as np

from lfspk.api import FRAME_SAMPLES, frame_count

from .select import activity, frame_db

SIR_DB = (-5.0, 5.0)
TURN_PROB = 0.5  # turn-taking: the interferer mostly outside the target's span
SEG_FRACTION = (0.3, 1.0)  # interferer segment length relative to the target
TURN_OVERLAP = (0.0, 0.3)  # fraction of the interferer segment overlapping the target in turn mode
PEAK = 0.99
NAME = "W2-simplemix-v2"


@dataclass(frozen=True)
class MixInfo:
    mode: str  # "overlap" (interferer inside the target's span) or "turn"
    sir_db: float
    target_offset: int  # samples
    offset: int  # interferer placement in the mixture, samples
    length: int  # interferer samples placed
    source_start: int  # where in the interferer utterance the placed segment starts
    gain: float  # applied to the interferer before the common peak scaling
    scale: float  # common scaling applied to both for the peak limit


def active_rms_db(x: np.ndarray, act: np.ndarray) -> float:
    """Mean power in dB over active 10 ms frames (whole signal if none)."""
    n = frame_count(x.size)
    padded = np.zeros(n * FRAME_SAMPLES)
    padded[: x.size] = x
    p = (padded.reshape(n, FRAME_SAMPLES) ** 2).mean(1)
    sel = p[act] if act.any() else p
    return float(10 * np.log10(max(sel.mean(), 1e-20)))


def _frames(n: int) -> int:
    return n - n % FRAME_SAMPLES


def mix(target: np.ndarray, interferer: np.ndarray, rng: np.random.Generator
        ) -> tuple[np.ndarray, np.ndarray, MixInfo]:
    """Mixture (float32), 10 ms labels (uint8 0/1/2/3), info.

    The interferer segment is SEG_FRACTION of the target's length (at most the
    interferer's own length), cut at a seeded point of the interferer
    utterance. Mode "overlap": placed inside the target's span. Mode "turn":
    placed before or after the target, overlapping it by TURN_OVERLAP of the
    segment; the mixture then extends beyond the target. All placements are
    10 ms aligned. Labels come from the clean sources with the fixed activity
    rule, each relative to its own loudest frame (scaling does not change
    them): 0 none, 1 target only, 2 interferer only, 3 both.
    """
    if target.ndim != 1 or interferer.ndim != 1 or target.size < FRAME_SAMPLES or interferer.size < FRAME_SAMPLES:
        raise ValueError("expected 1-D audio of at least one frame")
    n = _frames(target.size)
    target = target[:n]
    turn = bool(rng.random() < TURN_PROB)
    seg = _frames(max(FRAME_SAMPLES, min(int(n * rng.uniform(*SEG_FRACTION)), interferer.size)))
    src = _frames(int(rng.integers(0, interferer.size - seg + 1)))
    if turn:
        ov = _frames(int(seg * rng.uniform(*TURN_OVERLAP)))
        if rng.random() < 0.5:  # interferer first, then the target
            t_off, i_off = seg - ov, 0
        else:
            t_off, i_off = 0, n - ov
    else:
        t_off, i_off = 0, _frames(int(rng.integers(0, n - seg + 1)))
    total = max(t_off + n, i_off + seg)
    tgt = np.zeros(total)
    tgt[t_off:t_off + n] = target
    placed = np.zeros(total)
    placed[i_off:i_off + seg] = interferer[src:src + seg]
    act_t = activity(tgt, reference_db=float(frame_db(target).max()))
    act_i = activity(placed, reference_db=float(frame_db(interferer).max()))
    sir = float(rng.uniform(*SIR_DB))
    gain = 10 ** ((active_rms_db(tgt, act_t) - sir - active_rms_db(placed, act_i)) / 20)
    m = tgt + gain * placed
    peak = float(np.abs(m).max())
    scale = PEAK / peak if peak > PEAK else 1.0
    labels = act_t.astype(np.uint8) + 2 * act_i.astype(np.uint8)
    info = MixInfo("turn" if turn else "overlap", sir, t_off, i_off, seg, src, gain, scale)
    return (m * scale).astype(np.float32), labels, info


def encoder_targets(labels: np.ndarray, enc_frames: int) -> np.ndarray:
    """Soft target per 80 ms encoder frame: fraction of its 8 10 ms frames with
    target speech (label 1 or 3); frames beyond the labels count as 0."""
    tgt = np.isin(labels, (1, 3)).astype(np.float32)
    padded = np.zeros(enc_frames * 8, np.float32)
    k = min(tgt.size, padded.size)
    padded[:k] = tgt[:k]
    return padded.reshape(enc_frames, 8).mean(1)


def upsample_scores(enc_scores: np.ndarray, num_samples: int) -> np.ndarray:
    """80 ms scores -> 10 ms frames of the contract (repeat x8, pad with the last value)."""
    n = frame_count(num_samples)
    rep = np.repeat(np.asarray(enc_scores, np.float32), 8)
    if rep.size < n:
        rep = np.r_[rep, np.full(n - rep.size, rep[-1] if rep.size else 0.0, np.float32)]
    return rep[:n]
