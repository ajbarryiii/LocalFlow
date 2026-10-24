"""Parakeet's front end split at the mel power, the mask insertion and `apply` (DESIGN sections 3, 7, 10.1).

    P   = mel power (pre-emphasis 0.97, centred STFT n_fft 512 / hop 160 / Hann 400,
          |X| then squared as NeMo and LocalFlow do, Slaney filterbank [128, 257])
    X   = norm(log(P + 2^-24))                 Parakeet's features (the network input)
    X'  = norm(log(exp(w * log_mask) * P + 2^-24))

norm: per-feature mean and unbiased std (+1e-5) over the valid frames M = N // 160,
frames >= M set to 0 (NeMo FilterbankFeatures at inference; LocalFlow
VDSPFrontEnd). Every step mirrors NeMo's code operation for operation, and the
window and filterbank are the checkpoint's own buffers
(`lfspk.extract.constants`, hash-verified; review implI1-r1 #1). With the
same constants, `apply` equals the hook's features exactly (tests). W3's
analytic constants (`analytic_mel_power`) are for comparisons only.

This module is the reference implementation of `apply` (one recording, CPU).
The harness path (`nemo_hook`) applies the same mask inside NeMo's own
preprocessor so that, at log_mask = 0, it reproduces NeMo exactly.
"""

from __future__ import annotations

import numpy as np
import torch

from lfspk.pvad.features import HOP, LOG_GUARD, N_FFT, NORM_EPS, PREEMPH, WIN, hann_window, mel_filterbank

from .api import LOG_G_MIN, SMOOTH_FRAMES, InferenceConfig, MaskOutput, check_mask_output, feature_frames, valid_frames


class MelPower(torch.nn.Module):
    """[B, N] audio (zero past each length) -> mel power [B, 128, N // 160 + 1].

    Mirrors NeMo's FilterbankFeatures up to the filterbank product, operation
    for operation (pre-emphasis then time mask, `torch.stft` with the 400-point
    window and win_length 400, |X| then squared, a [1, 128, 257] filterbank
    matmul), so that with the same constants it equals NeMo's intermediate."""

    def __init__(self, window, fb):
        super().__init__()
        w = torch.as_tensor(np.asarray(window), dtype=torch.float32)
        f = torch.as_tensor(np.asarray(fb), dtype=torch.float32).reshape(1, 128, -1)
        if w.shape != (WIN,) or f.shape != (1, 128, N_FFT // 2 + 1):
            raise ValueError("window must be [400] and fb [128, 257]")
        self.register_buffer("window", w, persistent=False)
        self.register_buffer("fb", f, persistent=False)

    def forward(self, audio: torch.Tensor, lengths: torch.Tensor | None = None) -> torch.Tensor:
        if audio.ndim != 2:
            raise ValueError("audio must be [B, N]")
        b, n = audio.shape
        dev = audio.device
        x = audio.float()
        if lengths is None:
            lengths = torch.full((b,), n, dtype=torch.long, device=dev)
        lengths = lengths.to(dev).long()
        timemask = torch.arange(n, device=dev)[None, :] < lengths[:, None]
        x = torch.where(timemask, x, torch.zeros_like(x))
        x = torch.cat((x[:, 0].unsqueeze(1), x[:, 1:] - PREEMPH * x[:, :-1]), dim=1)
        x = x.masked_fill(~timemask, 0.0)
        spec = torch.stft(x, n_fft=N_FFT, hop_length=HOP, win_length=WIN, center=True, window=self.window,
                          return_complex=True, pad_mode="constant")
        mag = torch.sqrt(torch.view_as_real(spec).pow(2).sum(-1))
        return torch.matmul(self.fb.to(mag.dtype), mag.pow(2.0))


def log_norm(mel_power: torch.Tensor, lengths: torch.Tensor) -> torch.Tensor:
    """log(P + 2^-24), then NeMo's `normalize_batch(per_feature)` over each item's
    valid frames N // 160 (ported operation for operation), frames >= N // 160 = 0.
    [B, 128, T] -> [B, 128, T]."""
    x = torch.log(mel_power + LOG_GUARD)
    b, _, t = x.shape
    seq_len = lengths.to(x.device).long() // HOP
    valid = torch.arange(t, device=x.device).unsqueeze(0).expand(b, t) < seq_len.unsqueeze(1)
    num = torch.where(valid.unsqueeze(1), x, 0.0).sum(axis=2)
    den = valid.sum(axis=1)
    mean = num / den.unsqueeze(1)
    std = torch.sqrt(torch.sum(torch.where(valid.unsqueeze(1), x - mean.unsqueeze(2), 0.0) ** 2, axis=2)
                     / (den.unsqueeze(1) - 1.0))
    std = std.masked_fill(std.isnan(), 0.0)
    std = std + NORM_EPS
    out = (x - mean.unsqueeze(2)) / std.unsqueeze(2)
    return out.masked_fill(~valid.unsqueeze(1), 0.0)


_MP: MelPower | None = None


def parakeet_mel_power() -> MelPower:
    """MelPower with the constants of the checkpoint the harness transcribes
    with (`lfspk.extract.constants`, hash-verified). There is no fallback."""
    global _MP
    if _MP is None:
        from .constants import load

        _MP = MelPower(*load())
    return _MP


def analytic_mel_power() -> MelPower:
    """W3's analytic constants (tests and comparisons only; not what `apply` uses)."""
    return MelPower(hann_window(), mel_filterbank())


def mel_power_np(audio: np.ndarray, mel: MelPower | None = None) -> np.ndarray:
    """One recording -> float32 [128, N // 160 + 1] mel power."""
    with torch.no_grad():
        p = (mel or parakeet_mel_power())(torch.from_numpy(np.ascontiguousarray(audio, dtype=np.float32))[None])
    return p[0].numpy()


def features_np(audio: np.ndarray, mel: MelPower | None = None) -> np.ndarray:
    """X: Parakeet's normalised log-mel of one recording, float32 [128, N // 160 + 1]."""
    with torch.no_grad():
        a = torch.from_numpy(np.ascontiguousarray(audio, dtype=np.float32))[None]
        out = log_norm((mel or parakeet_mel_power())(a), torch.tensor([a.shape[1]]))
    return out[0].numpy()


def smooth_u(u: np.ndarray, num_samples: int) -> np.ndarray:
    """ubar: centred moving average of u over SMOOTH_FRAMES frames, using valid
    frames only (an edge frame averages the valid frames its window covers).
    Frames >= N // 160 are 0."""
    t, m = feature_frames(num_samples), valid_frames(num_samples)
    u = np.asarray(u, dtype=np.float64)
    if u.shape != (t,):
        raise ValueError(f"u must have {t} frames")
    out = np.zeros(t, dtype=np.float64)
    if m == 0:
        return out.astype(np.float32)
    h = SMOOTH_FRAMES // 2
    c = np.concatenate([[0.0], np.cumsum(u[:m])])
    idx = np.arange(m)
    lo, hi = np.maximum(idx - h, 0), np.minimum(idx + h + 1, m)
    out[:m] = (c[hi] - c[lo]) / (hi - lo)
    return out.astype(np.float32)


def weights(u: np.ndarray, num_samples: int, config: InferenceConfig) -> np.ndarray | None:
    """w(t) for a recording under `config`, or None if the recording is bypassed.

    C1: w = 1. C2-C4: w = s * ubar. C3/C4 bypass when max_t ubar < theta_b
    (max over valid frames; a recording without valid frames is bypassed)."""
    t, m = feature_frames(num_samples), valid_frames(num_samples)
    if not config.adaptive:
        return np.ones(t, dtype=np.float32)
    ubar = smooth_u(u, num_samples)
    if config.bypass and (m == 0 or float(ubar[:m].max()) < float(config.theta_b)):
        return None
    return (config.strength * ubar).astype(np.float32)


def bypassed(out: MaskOutput, num_samples: int, config: InferenceConfig) -> bool:
    """True when `config` bypasses this recording (apply would return None)."""
    return weights(out.u, num_samples, config) is None


def masked_log_norm(mel_power: torch.Tensor, log_mask: torch.Tensor, w: torch.Tensor, lengths: torch.Tensor) -> torch.Tensor:
    """X' for a batch: P [B, 128, T], log_mask [B, 128, T], w [B, T], lengths [B] samples."""
    return log_norm(mel_power * torch.exp(w[:, None, :] * log_mask), lengths)


def apply(audio: np.ndarray, out: MaskOutput, config: InferenceConfig, mel: MelPower | None = None) -> np.ndarray | None:
    """The features Parakeet's encoder sees for one recording, float32
    [128, N // 160 + 1], or None when `config` bypasses it (the caller then uses
    the unmodified path: B's cached transcript in the harness). `mel` defaults
    to Parakeet's checkpoint constants."""
    n = int(audio.shape[0])
    check_mask_output(out, n)
    w = weights(out.u, n, config)
    if w is None:
        return None
    with torch.no_grad():
        a = torch.from_numpy(np.ascontiguousarray(audio, dtype=np.float32))[None]
        p = (mel or parakeet_mel_power())(a)
        lm = torch.from_numpy(np.asarray(out.log_mask, dtype=np.float32))[None]
        x = masked_log_norm(p, lm, torch.from_numpy(w)[None], torch.tensor([n]))
    return x[0].numpy()


def ideal_log_mask(p_target: torch.Tensor, p_mix: torch.Tensor) -> torch.Tensor:
    """log m* = clip(log(P(y*) / P(mix)), log g_min, 0) (DESIGN section 4), the raw
    clipped ratio wherever P(mix) > 0 (review implI1-r1 #4). Zero-power cases:
    P(mix) = 0 -> 0 (nothing to remove; a digitally silent bin); P(y*) = 0 <
    P(mix) -> log g_min (the floor)."""
    with torch.no_grad():
        r = (torch.log(p_target) - torch.log(p_mix)).clamp(min=LOG_G_MIN, max=0.0)
        return torch.where(p_mix > 0, r, torch.zeros_like(r))


def guard_regime_share(mel_power: np.ndarray, num_samples: int) -> float:
    """Share of valid (t, f) bins with g_min P < 100 eps: where even the floored
    mask can enter the log guard's regime (DESIGN section 3, measured on stage 0)."""
    m = valid_frames(num_samples)
    if m == 0:
        return 0.0
    from .api import G_MIN

    p = np.asarray(mel_power, dtype=np.float64)[:, :m]
    return float(np.mean(G_MIN * p < 100.0 * LOG_GUARD))


__all__ = ["MelPower", "parakeet_mel_power", "analytic_mel_power", "log_norm", "mel_power_np", "features_np", "smooth_u", "weights", "masked_log_norm", "apply",
           "ideal_log_mask", "guard_regime_share", "MaskOutput", "InferenceConfig"]
