"""Speech activity of a dry source and the 0/1/2/3 frame labels (DESIGN.md section 5).

The rule is fixed, deterministic and per track, so it runs on the fly for
training data. It is relative to the track's own level, so the absolute gain of
a dry source never changes its activity.
"""

from __future__ import annotations

from dataclasses import dataclass

import numpy as np

from ..api import frame_count
from .util import db, frame_power

NO_SPEECH, TARGET, INTERFERER, OVERLAP = 0, 1, 2, 3


@dataclass(frozen=True)
class ActivityRule:
    rel_peak_db: float = 35.0  # threshold no lower than the 95th percentile level minus this
    floor_margin_db: float = 8.0  # and no lower than the noise floor plus this
    max_rel_db: float = 15.0  # but never higher than the 95th percentile level minus this
    floor_min_dbfs: float = -70.0  # noise-floor bounds, as in LocalFlow's silence gate
    floor_max_dbfs: float = -40.0
    peak_percentile: float = 95.0
    floor_percentile: float = 5.0
    floor_smooth_frames: int = 5
    min_gap_frames: int = 10  # interior gaps shorter than 100 ms are filled
    min_run_frames: int = 3  # active runs shorter than 30 ms are dropped
    dilate_frames: int = 1


DEFAULT_RULE = ActivityRule()


def _runs(mask: np.ndarray) -> list[tuple[int, int]]:
    """[start, end) of each True run."""
    if mask.size == 0:
        return []
    d = np.diff(np.concatenate([[0], mask.astype(np.int8), [0]]))
    starts = np.flatnonzero(d == 1)
    ends = np.flatnonzero(d == -1)
    return list(zip(starts.tolist(), ends.tolist()))


def runs(mask: np.ndarray) -> list[tuple[int, int]]:
    return _runs(np.asarray(mask, dtype=bool))


def activity(x: np.ndarray, rule: ActivityRule = DEFAULT_RULE) -> np.ndarray:
    """Boolean speech activity per 10 ms frame of the dry track x."""
    n = frame_count(x.size)
    p = frame_power(x)
    live = p > 0.0
    out = np.zeros(n, dtype=bool)
    if not live.any():
        return out
    lev = np.asarray(db(p))
    hi = float(np.percentile(lev[live], rule.peak_percentile))
    # The noise floor is bounded the way LocalFlow's silence gate bounds its own
    # (ParakeetSilenceCompactor: -70...-40 dBFS). It is estimated only from
    # frames at or above the lower bound, so digital zeros, +-1 LSB dither and
    # any other padding below -70 dBFS cannot drag it down (r1-r3), and the
    # estimate is clamped to the bounds. dBFS refers to the dry source file's own
    # level, before any mixing gain.
    k = max(1, rule.floor_smooth_frames)
    audible = lev[live & (lev >= rule.floor_min_dbfs)]
    if audible.size:
        smooth = np.convolve(audible, np.ones(k) / k, mode="valid") if audible.size >= k else audible
        estimate = float(np.percentile(smooth, rule.floor_percentile))
    else:
        estimate = rule.floor_min_dbfs
    floor = min(max(estimate, rule.floor_min_dbfs), rule.floor_max_dbfs)
    # A track whose non-zero frames are all speech (no room tone visible, e.g. a
    # burst padded with zeros) keeps speech within max_rel_db of its 95th
    # percentile level.
    theta = min(max(hi - rule.rel_peak_db, floor + rule.floor_margin_db), hi - rule.max_rel_db)
    act = live & (lev >= theta)
    # Fill interior gaps shorter than min_gap_frames.
    r = _runs(act)
    for (s0, e0), (s1, _) in zip(r, r[1:]):
        if s1 - e0 < rule.min_gap_frames:
            act[e0:s1] = True
    # Drop short isolated runs.
    for s, e in _runs(act):
        if e - s < rule.min_run_frames:
            act[s:e] = False
    # Dilate.
    if rule.dilate_frames > 0 and act.any():
        d = rule.dilate_frames
        idx = np.flatnonzero(act)
        grown = np.zeros(n, dtype=bool)
        for off in range(-d, d + 1):
            j = idx + off
            grown[j[(j >= 0) & (j < n)]] = True
        act = grown
    return act


def place(act: np.ndarray, offset_frames: int, total_frames: int) -> np.ndarray:
    """Shift an activity array to `offset_frames` (may be negative) inside a
    timeline of `total_frames`, cropping what falls outside."""
    out = np.zeros(total_frames, dtype=bool)
    s = max(0, offset_frames)
    e = min(total_frames, offset_frames + act.size)
    if e > s:
        out[s:e] = act[s - offset_frames : e - offset_frames]
    return out


def compose_labels(target_active: np.ndarray, interferer_active: np.ndarray) -> np.ndarray:
    """0 none, 1 target only, 2 interferer only, 3 both."""
    if target_active.shape != interferer_active.shape:
        raise ValueError("activity arrays differ in length")
    return (target_active.astype(np.uint8) + 2 * interferer_active.astype(np.uint8)).astype(np.uint8)
