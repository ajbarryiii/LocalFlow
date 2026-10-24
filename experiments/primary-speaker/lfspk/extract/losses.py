"""Training losses (DESIGN section 5).

Asymmetric L2 on the log mask: x = log m* - log m (> 0 means m removes energy
the target y* keeps: over-suppression), g(x, a) = x if x <= 0 else a x,
a = 10 (VoiceFilter-Lite), averaged over valid (t, f) bins. Auxiliary:
binary cross-entropy of the interference logit against labels relative to the
conditioning identity, averaged over valid frames, weight 0.1.
"""

from __future__ import annotations

import torch
import torch.nn.functional as F

ALPHA = 10.0
LAMBDA_AUX = 0.1


def asymmetric(x: torch.Tensor, alpha: float = ALPHA) -> torch.Tensor:
    return torch.where(x > 0, alpha * x, x)


def mask_loss(log_mask: torch.Tensor, ideal_log_mask: torch.Tensor, valid: torch.Tensor, alpha: float = ALPHA) -> torch.Tensor:
    """log_mask, ideal_log_mask [B, 128, T]; valid [B, T] (1 = frame counts)."""
    v = valid.to(log_mask.dtype)[:, None, :]
    se = asymmetric(ideal_log_mask - log_mask, alpha).square() * v
    return se.sum() / (v.sum() * log_mask.shape[1]).clamp(min=1.0)


def aux_loss(u_logit: torch.Tensor, labels: torch.Tensor, valid: torch.Tensor) -> torch.Tensor:
    """u_logit, labels (0/1), valid: [B, T]."""
    v = valid.to(u_logit.dtype)
    ce = F.binary_cross_entropy_with_logits(u_logit, labels.to(u_logit.dtype), reduction="none") * v
    return ce.sum() / v.sum().clamp(min=1.0)


def total_loss(log_mask, u_logit, ideal_log_mask, labels, valid, alpha: float = ALPHA,
               lambda_aux: float = LAMBDA_AUX) -> tuple[torch.Tensor, dict[str, float]]:
    lm = mask_loss(log_mask, ideal_log_mask, valid, alpha)
    la = aux_loss(u_logit, labels, valid)
    return lm + lambda_aux * la, {"mask": float(lm.detach()), "aux": float(la.detach())}
