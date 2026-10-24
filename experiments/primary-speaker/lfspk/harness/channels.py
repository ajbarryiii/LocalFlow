"""Microphone, loudspeaker and telephony colourings (DESIGN.md sections 3.1-3.2).

Everything is parametric: no measured device responses are available to us.
A colouring is a JSON-serialisable parameter dict plus a pure `apply`.
Device parameters are drawn once per (split, speaker, device), so a user owns
one laptop and one headset.
"""

from __future__ import annotations

from typing import Any

import numpy as np
from scipy import signal

from ..api import SAMPLE_RATE
from .util import EPS, biquad_peaking, biquad_shelf, butter, rng_for, sosfilt

DEVICES = ("builtin", "headset")


# --- microphones ----------------------------------------------------------------


def draw_device(split: str, speaker_id: str, device: str) -> dict[str, Any]:
    """The fixed colouring of a user's device."""
    if device not in DEVICES:
        raise ValueError(f"unknown device {device!r}")
    rng = rng_for("device", split, speaker_id, device)
    if device == "builtin":
        return {
            "device": device,
            "hpf_hz": float(rng.uniform(100, 200)),
            "presence_hz": float(rng.uniform(2500, 5000)),
            "presence_db": float(rng.uniform(0, 5)),
            "hishelf_db": float(rng.uniform(-6, 0)),
            "self_noise_dbfs": float(rng.uniform(-72, -62)),
        }
    return {
        "device": device,
        "hpf_hz": float(rng.uniform(60, 100)),
        "lpf_hz": float(rng.uniform(6500, 7500)),
        "proximity_db": float(rng.uniform(0, 6)),
        "self_noise_dbfs": float(rng.uniform(-82, -72)),
    }


def device_sos(p: dict[str, Any]) -> np.ndarray:
    """Linear response shared by every source reaching the microphone."""
    if p["device"] == "builtin":
        return np.vstack(
            [
                butter(2, p["hpf_hz"], "highpass"),
                biquad_peaking(p["presence_hz"], p["presence_db"], 1.0),
                biquad_shelf(6000.0, p["hishelf_db"], high=True),
            ]
        )
    return np.vstack([butter(2, p["hpf_hz"], "highpass"), butter(4, p["lpf_hz"], "lowpass")])


def proximity_sos(p: dict[str, Any]) -> np.ndarray:
    """Near-source-only bass boost of a close-talking headset (target image only)."""
    if p["device"] != "headset" or p["proximity_db"] <= 0:
        return np.zeros((0, 6))
    return biquad_shelf(200.0, p["proximity_db"], high=False)


def apply_device(x: np.ndarray, p: dict[str, Any], near_source: bool = False) -> np.ndarray:
    y = sosfilt(device_sos(p), x)
    if near_source:
        y = sosfilt(proximity_sos(p), y)
    return y


# --- loudspeakers -----------------------------------------------------------------


def soft_clip(x: np.ndarray, drive: float) -> np.ndarray:
    """tanh saturation at `drive` relative to the signal's 99.9th percentile peak.
    drive 0 is the identity; output keeps the input's active scale."""
    if drive <= 0 or x.size == 0:
        return x.astype(np.float32, copy=True)
    ref = float(np.percentile(np.abs(x), 99.9)) + EPS
    k = drive / ref
    return (np.tanh(k * x.astype(np.float64)) / k).astype(np.float32)


def draw_tv_speaker(rng: np.random.Generator) -> dict[str, Any]:
    return {
        "kind": "tv",
        "hpf_hz": float(rng.uniform(80, 150)),
        "res": [[float(rng.uniform(200, 4000)), float(rng.uniform(-4, 4)), float(rng.uniform(1, 3))] for _ in range(2)],
        "drive": float(rng.uniform(0.3, 1.0)),
    }


def draw_laptop_speaker(rng: np.random.Generator) -> dict[str, Any]:
    return {
        "kind": "laptop",
        "hpf_hz": float(rng.uniform(250, 450)),
        "res": [[float(rng.uniform(800, 2500)), float(rng.uniform(6, 10)), float(rng.uniform(1, 2))]],
        "drive": float(rng.uniform(0.8, 1.6)),
    }


def apply_speaker(x: np.ndarray, p: dict[str, Any]) -> np.ndarray:
    sos = np.vstack([butter(4, p["hpf_hz"], "highpass")] + [biquad_peaking(f, g, q) for f, g, q in p["res"]])
    return soft_clip(sosfilt(sos, x), p["drive"])


# --- broadcast dynamics -------------------------------------------------------------


def compress(x: np.ndarray, threshold_db: float = -20.0, ratio: float = 3.0, attack_s: float = 0.01, release_s: float = 0.2) -> np.ndarray:
    """Feed-forward RMS compressor; threshold is relative to the signal's 95th
    percentile 10 ms level, so it is gain-independent."""
    if x.size == 0:
        return x.astype(np.float32, copy=True)
    x64 = x.astype(np.float64)
    hop = 160
    n = int(np.ceil(x64.size / hop))
    pad = np.pad(x64, (0, n * hop - x64.size))
    lev = 10 * np.log10(np.mean(pad.reshape(n, hop) ** 2, axis=1) + EPS)
    ref = np.percentile(lev, 95) + threshold_db
    a_att = np.exp(-hop / (attack_s * SAMPLE_RATE))
    a_rel = np.exp(-hop / (release_s * SAMPLE_RATE))
    env = np.empty(n)
    e = lev[0]
    for i, v in enumerate(lev):
        a = a_att if v > e else a_rel
        e = a * e + (1 - a) * v
        env[i] = e
    over = np.maximum(env - ref, 0.0)
    gain_db = -over * (1 - 1 / ratio)
    gain = np.repeat(10 ** (gain_db / 20), hop)[: x64.size]
    return (x64 * gain).astype(np.float32)


# --- telephony / VoIP -----------------------------------------------------------------

MU = 255.0


def mulaw_roundtrip(x: np.ndarray) -> np.ndarray:
    """G.711 mu-law: compand, quantise to 8 bits, expand. Input in [-1, 1]."""
    x = np.clip(x.astype(np.float64), -1.0, 1.0)
    y = np.sign(x) * np.log1p(MU * np.abs(x)) / np.log1p(MU)
    q = np.round((y + 1) / 2 * 255) / 255 * 2 - 1
    return (np.sign(q) * np.expm1(np.abs(q) * np.log1p(MU)) / MU).astype(np.float32)


def _normalise_peak(x: np.ndarray, target_rms_db: float = -20.0) -> tuple[np.ndarray, float]:
    rms = np.sqrt(np.mean(x.astype(np.float64) ** 2)) + EPS
    g = 10 ** (target_rms_db / 20) / rms
    return (x * g).astype(np.float32), float(g)


def narrowband(x: np.ndarray) -> np.ndarray:
    """PSTN: 8 kHz, 300-3400 Hz band, G.711 mu-law at a nominal -20 dBov."""
    x8 = signal.resample_poly(x.astype(np.float64), 1, 2)
    x8 = signal.sosfilt(signal.butter(4, (300, 3400), btype="bandpass", fs=8000, output="sos"), x8).astype(np.float32)
    xn, g = _normalise_peak(x8)
    y8 = mulaw_roundtrip(xn) / g
    y = signal.resample_poly(y8.astype(np.float64), 2, 1)[: x.size]
    return np.pad(y, (0, x.size - y.size)).astype(np.float32)


def draw_voip(rng: np.random.Generator) -> dict[str, Any]:
    return {"kind": "voip", "q": float(rng.uniform(0.3, 0.7)), "loss": float(rng.uniform(0.0, 0.03)), "seed": int(rng.integers(2**31))}


def voip(x: np.ndarray, p: dict[str, Any]) -> np.ndarray:
    """Wideband VoIP stand-in: 50-7000 Hz band, transform-domain quantisation with
    spectral holes (a low-bitrate codec's signature) and 20 ms packet loss with
    repetition concealment. Not a real codec; see DESIGN.md section 12."""
    if x.size == 0:
        return x.astype(np.float32, copy=True)
    xb = sosfilt(butter(4, (50, 7000), "bandpass"), x).astype(np.float64)
    f, t, z = signal.stft(xb, fs=SAMPLE_RATE, nperseg=320, noverlap=160, window="hann")
    mag, ph = np.abs(z), np.angle(z)
    edges = np.unique(np.round(np.geomspace(1, mag.shape[0] - 1, 22)).astype(int))
    out = np.zeros_like(mag)
    for lo, hi in zip(edges[:-1], edges[1:]):
        band = mag[lo:hi]
        rms = np.sqrt(np.mean(band**2, axis=0, keepdims=True)) + EPS
        step = p["q"] * rms
        qb = np.round(band / step) * step
        qb[band < 0.1 * rms] = 0.0
        out[lo:hi] = qb
    _, y = signal.istft(out * np.exp(1j * ph), fs=SAMPLE_RATE, nperseg=320, noverlap=160, window="hann")
    y = np.pad(y[: x.size], (0, max(0, x.size - y.size)))
    if p["loss"] > 0:
        r = np.random.Generator(np.random.PCG64(p["seed"]))
        pk = 320
        prev = np.zeros(pk)
        fade = 1.0
        for s in range(0, y.size, pk):
            seg = y[s : s + pk]
            if r.random() < p["loss"]:
                fade *= 0.6
                seg[:] = prev[: seg.size] * fade
            else:
                fade = 1.0
                prev = np.pad(seg.copy(), (0, pk - seg.size))
    return y.astype(np.float32)


def draw_call_channel(rng: np.random.Generator) -> dict[str, Any]:
    if rng.random() < 0.4:
        return {"kind": "narrowband"}
    return draw_voip(rng)


def apply_call_channel(x: np.ndarray, p: dict[str, Any]) -> np.ndarray:
    return narrowband(x) if p["kind"] == "narrowband" else voip(x, p)
