"""Masked statistics pooling over time. Torch only; no NeMo import."""

from __future__ import annotations

import torch


def valid_mask(lengths: torch.Tensor, steps: int) -> torch.Tensor:
    """[B, T] bool, True for frames t < lengths[b]."""
    return torch.arange(steps, device=lengths.device)[None, :] < lengths[:, None]


def mean_std(x: torch.Tensor, lengths: torch.Tensor) -> torch.Tensor:
    """x [B, T, D], lengths [B] -> [B, 2D] = (mean, std) over valid frames.

    Computed in float64 so padding and batch composition do not change the
    result beyond rounding. std is the population standard deviation; a
    single valid frame gives std 0. Raises on a zero length.
    """
    if x.dim() != 3 or lengths.dim() != 1 or lengths.numel() != x.size(0):
        raise ValueError("expected x [B, T, D] and lengths [B]")
    if (lengths <= 0).any() or (lengths > x.size(1)).any():
        raise ValueError("lengths must be in [1, T]")
    m = valid_mask(lengths, x.size(1)).to(torch.float64)[..., None]
    xd = x.to(torch.float64)
    n = lengths.to(torch.float64)[:, None]
    mean = (xd * m).sum(1) / n
    var = (((xd - mean[:, None, :]) ** 2) * m).sum(1) / n
    return torch.cat([mean, var.clamp_min(0).sqrt()], dim=1)
