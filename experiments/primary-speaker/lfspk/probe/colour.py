"""W2-colour-v1: a fixed device colouring for the stage-2 channel-mismatch control
(DESIGN 5.4). Labelled W2's own; replaced by W0's device colourings once they
are announced. Applied to dev test segments only, never to enrollment.

Chain: 2nd-order Butterworth high-pass at 200 Hz (small laptop capsule),
+6 dB peaking EQ at 3 kHz, Q 1 (presence peak), 4th-order Butterworth
low-pass at 6 kHz (cheap capsule roll-off), then a common gain so the peak
stays below 0.99.
"""

from __future__ import annotations

import numpy as np

NAME = "W2-colour-v1"
SR = 16000


def _peaking(f0: float, gain_db: float, q: float) -> np.ndarray:
    """RBJ cookbook peaking biquad as one SOS row."""
    a = 10 ** (gain_db / 40)
    w0 = 2 * np.pi * f0 / SR
    alpha = np.sin(w0) / (2 * q)
    b = np.array([1 + alpha * a, -2 * np.cos(w0), 1 - alpha * a])
    den = np.array([1 + alpha / a, -2 * np.cos(w0), 1 - alpha / a])
    return np.r_[b / den[0], den / den[0]][None, :]


def sos() -> np.ndarray:
    from scipy.signal import butter

    return np.concatenate([butter(2, 200, "highpass", fs=SR, output="sos"), _peaking(3000.0, 6.0, 1.0),
                           butter(4, 6000, "lowpass", fs=SR, output="sos")])


def colour(audio: np.ndarray) -> np.ndarray:
    from scipy.signal import sosfilt

    y = sosfilt(sos(), audio.astype(np.float64))
    peak = float(np.abs(y).max()) if y.size else 0.0
    if peak > 0.99:
        y *= 0.99 / peak
    return y.astype(np.float32)
