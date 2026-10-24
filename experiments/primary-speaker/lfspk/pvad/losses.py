"""Labels and losses (DESIGN.md section 4.4)."""

from __future__ import annotations

import numpy as np
import torch
import torch.nn.functional as F

from .model import NS, NTSS, TSS

# Contract frame labels: 0 no speech, 1 target only, 2 interferer only, 3 overlap.
_CONTRACT_TO_CLASS = np.array([NS, TSS, NTSS, TSS], dtype=np.int64)


def classes_from_contract(labels: np.ndarray, target_present: bool = True) -> np.ndarray:
    """Contract labels -> PVAD classes. With target_present False (the conditioning
    speaker is absent from the mixture) every speech frame is non-target."""
    labels = np.asarray(labels)
    if labels.size and (labels.min() < 0 or labels.max() > 3):
        raise ValueError("contract labels must be in 0..3")
    out = _CONTRACT_TO_CLASS[labels.astype(np.int64)]
    if not target_present:
        out = np.where(out == NS, NS, NTSS)
    return out


def wpl_weights(w_ns_ntss: float = 0.1) -> torch.Tensor:
    """Symmetric pair weights w[y, k]: pairs with tss weigh 1, ns/ntss weighs w_ns_ntss."""
    w = torch.ones(3, 3)
    w[NS, NTSS] = w[NTSS, NS] = w_ns_ntss
    w.fill_diagonal_(0.0)
    return w


def weighted_pairwise_loss(logits: torch.Tensor, target: torch.Tensor, mask: torch.Tensor,
                           weights: torch.Tensor | None = None) -> torch.Tensor:
    """Ding et al. 2020: -E_{k != y}[ w<k,y> log(e^{z_y} / (e^{z_y} + e^{z_k})) ], mean over valid frames.

    logits [B, 3, T], target [B, T] int in {0, 1, 2}, mask [B, T] (1 = counts)."""
    w = (wpl_weights() if weights is None else weights).to(logits.device, logits.dtype)
    z = logits.transpose(1, 2)  # [B, T, 3]
    tgt = target.clamp(0, 2).long()
    onehot = F.one_hot(tgt, 3).to(z.dtype)
    zy = (z * onehot).sum(-1, keepdim=True)  # [B, T, 1]; not gather, whose CUDA backward is a scatter_add
    pair = F.logsigmoid(zy - z)  # log e^{zy} / (e^{zy} + e^{zk})
    wy = w[tgt]  # [B, T, 3], zero at k == y
    per_frame = -(wy * pair).sum(-1) / 2.0  # expectation over the two k != y
    m = mask.to(logits.dtype)
    return (per_frame * m).sum() / m.sum().clamp(min=1.0)


def masked_cross_entropy(logits: torch.Tensor, target: torch.Tensor, mask: torch.Tensor) -> torch.Tensor:
    ce = F.cross_entropy(logits, target.clamp(0, 2).long(), reduction="none")
    m = mask.to(logits.dtype)
    return (ce * m).sum() / m.sum().clamp(min=1.0)


def p_target(logits: torch.Tensor) -> torch.Tensor:
    """Softmax P(tss) [B, T] from logits [B, 3, T]."""
    return torch.softmax(logits.float(), dim=1)[:, TSS]
