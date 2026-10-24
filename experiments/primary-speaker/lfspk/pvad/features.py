"""Parakeet TDT 0.6B v2's log-mel front end, batched in torch.

Matches LocalFlow's `VDSPFrontEnd` (Sources/Parakeet/ParakeetFrontEnd.swift),
itself NeMo's FilterbankFeatures at inference: dither off; pre-emphasis 0.97
(y[0] = x[0]); centred STFT with n_fft 512, hop 160 and constant zero padding of
256 on both sides; the symmetric Hann window of 400 centred in 512; |X|^2;
Slaney mel filterbank [128, 257]; log(x + 2^-24); per-feature normalisation over
the valid frames M = N // 160 (mean, unbiased std + 1e-5); frames >= M are 0.
Output [B, 128, N // 160 + 1].

Contract frame i (samples [160 i, 160 i + 160)) is mel frame i.
"""

from __future__ import annotations

import math

import numpy as np
import torch

N_FFT = 512
HOP = 160
WIN = 400
N_MELS = 128
N_BINS = N_FFT // 2 + 1
PREEMPH = 0.97
LOG_GUARD = 2.0 ** -24
NORM_EPS = 1e-5


def hann_window() -> torch.Tensor:
    """Symmetric Hann of 400 (torch.hann_window(periodic=False), as NeMo stores)."""
    return torch.hann_window(WIN, periodic=False, dtype=torch.float64).float()


def _hz_to_mel_slaney(f: np.ndarray) -> np.ndarray:
    f = np.asarray(f, dtype=np.float64)
    f_sp = 200.0 / 3
    mels = f / f_sp
    min_log_hz = 1000.0
    min_log_mel = min_log_hz / f_sp
    logstep = math.log(6.4) / 27.0
    return np.where(f >= min_log_hz, min_log_mel + np.log(np.maximum(f, 1e-10) / min_log_hz) / logstep, mels)


def _mel_to_hz_slaney(m: np.ndarray) -> np.ndarray:
    m = np.asarray(m, dtype=np.float64)
    f_sp = 200.0 / 3
    freqs = f_sp * m
    min_log_hz = 1000.0
    min_log_mel = min_log_hz / f_sp
    logstep = math.log(6.4) / 27.0
    return np.where(m >= min_log_mel, min_log_hz * np.exp(logstep * (m - min_log_mel)), freqs)


def mel_filterbank(sr: int = 16_000) -> torch.Tensor:
    """librosa.filters.mel(sr, 512, n_mels=128, fmin=0, fmax=sr/2, htk=False, norm='slaney'): [128, 257]."""
    fftfreqs = np.linspace(0, sr / 2, N_BINS)
    mel_f = _mel_to_hz_slaney(np.linspace(_hz_to_mel_slaney(0.0), _hz_to_mel_slaney(sr / 2), N_MELS + 2))
    fdiff = np.diff(mel_f)
    ramps = mel_f[:, None] - fftfreqs[None, :]
    lower = -ramps[:-2] / fdiff[:-1, None]
    upper = ramps[2:] / fdiff[1:, None]
    weights = np.maximum(0, np.minimum(lower, upper))
    enorm = 2.0 / (mel_f[2: N_MELS + 2] - mel_f[:N_MELS])
    weights *= enorm[:, None]
    return torch.from_numpy(weights.astype(np.float32))


class ParakeetFrontEnd(torch.nn.Module):
    def __init__(self, window: torch.Tensor | None = None, fb: torch.Tensor | None = None):
        super().__init__()
        w = hann_window() if window is None else window.float()
        if w.shape != (WIN,):
            raise ValueError("window must have 400 values")
        w512 = torch.zeros(N_FFT)
        off = (N_FFT - WIN) // 2
        w512[off: off + WIN] = w
        fb = mel_filterbank() if fb is None else fb.float()
        if fb.shape != (N_MELS, N_BINS):
            raise ValueError("filterbank must be [128, 257]")
        self.register_buffer("window512", w512, persistent=False)
        self.register_buffer("fb", fb, persistent=False)

    @staticmethod
    def frames(num_samples: int) -> int:
        return num_samples // HOP + 1

    @torch.no_grad()
    def forward(self, audio: torch.Tensor, lengths: torch.Tensor | None = None) -> torch.Tensor:
        """audio [B, N] float (zero past each length); lengths [B] samples. -> [B, 128, N // 160 + 1].

        Each item is processed as if it were a recording of exactly `lengths[b]`
        samples: pre-emphasis and normalisation only see the valid samples and
        frames, and frames at or beyond lengths[b] // 160 are 0.
        """
        if audio.ndim != 2:
            raise ValueError("audio must be [B, N]")
        b, n = audio.shape
        dev = audio.device
        x = audio.float()
        if lengths is None:
            lengths = torch.full((b,), n, dtype=torch.long, device=dev)
        lengths = lengths.to(dev).long()
        idx = torch.arange(n, device=dev)
        inside = idx[None, :] < lengths[:, None]
        x = torch.where(inside, x, torch.zeros_like(x))
        y = torch.cat([x[:, :1], x[:, 1:] - PREEMPH * x[:, :-1]], dim=1)
        y = torch.where(inside, y, torch.zeros_like(y))
        # torch.stft(center=True, pad_mode="constant") pads n_fft // 2 each side with zeros.
        spec = torch.stft(y, n_fft=N_FFT, hop_length=HOP, win_length=N_FFT, window=self.window512,
                          center=True, pad_mode="constant", return_complex=True)
        power = spec.real.square() + spec.imag.square()  # [B, 257, T]
        mel = torch.log(torch.matmul(self.fb, power) + LOG_GUARD)  # [B, 128, T]
        t = mel.shape[-1]
        valid = lengths // HOP  # [B]
        fmask = (torch.arange(t, device=dev)[None, :] < valid[:, None]).float()[:, None, :]  # [B,1,T]
        cnt = valid.clamp(min=1).float()[:, None, None]
        mean = (mel * fmask).sum(-1, keepdim=True) / cnt
        var = ((mel - mean).square() * fmask).sum(-1, keepdim=True) / (valid.float()[:, None, None] - 1).clamp(min=1e-12)
        std = torch.sqrt(var)
        std = torch.where(valid[:, None, None] > 1, std, torch.zeros_like(std)) + NORM_EPS
        out = (mel - mean) / std * fmask
        # Items shorter than the batch: frames past their own N // 160 + 1 are not part of them.
        return out


def features_np(audio: np.ndarray, frontend: ParakeetFrontEnd | None = None) -> np.ndarray:
    """One recording -> float32 [128, N // 160 + 1]."""
    fe = frontend or ParakeetFrontEnd()
    with torch.no_grad():
        out = fe(torch.from_numpy(np.ascontiguousarray(audio, dtype=np.float32))[None])
    return out[0].numpy()
