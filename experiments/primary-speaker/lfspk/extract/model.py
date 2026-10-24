"""The speaker-conditioned mask network (DESIGN section 6).

W5's own copy of W3's trunk design (dilated depthwise-separable blocks with
FiLM and an in-network cosine branch; `lfspk/pvad/model.py`), so that W3's
code changes cannot alter W5 checkpoints. Heads: a mask on mel power, two
10 ms frames per 50 fps step ("sub-pixel"), parameterised as
log m = log(g_min) * (1 - sigmoid(z)) so m lies in [g_min, 1]; and the
interference probability u(t), also two frames per step.

The mask head's bias starts at MASK_BIAS_INIT so the untrained network passes
features through (weights zero, so log m = log(g_min) (1 - sigmoid(5)), about
-0.2 dB) instead of starting at -15 dB; gradients still reach the weights.
"""

from __future__ import annotations

from dataclasses import asdict, dataclass

import torch
import torch.nn.functional as F
from torch import nn

from .api import LOG_G_MIN, N_MELS

DILATIONS = (1, 3, 9, 27)
MASK_BIAS_INIT = 5.0
LINEAR_BIAS_INIT = -0.05  # "linear" head (screen VA): log m = clamp(z, log g_min, 0), starting at about -0.2 dB
HEADS = ("sigmoid", "linear")
SIZES = {"S": dict(channels=96), "M": dict(channels=128)}
CONDITIONINGS = ("film_cos", "none")


@dataclass(frozen=True)
class MaskNetConfig:
    channels: int = 128
    blocks: int = 8
    kernel: int = 5
    expansion: int = 2
    proj_dim: int = 64
    cos_dim: int = 32
    emb_dim: int = 192
    n_mels: int = N_MELS
    conditioning: str = "film_cos"  # "none" = R2 (FiLM identity, no cos branch)
    head: str = "sigmoid"  # "sigmoid": log m = log g_min (1 - sigmoid(z)); "linear": clamp(z, log g_min, 0)

    def __post_init__(self):
        if self.conditioning not in CONDITIONINGS:
            raise ValueError(f"conditioning must be one of {CONDITIONINGS}")
        if self.head not in HEADS:
            raise ValueError(f"head must be one of {HEADS}")
        if self.blocks % 2 or self.blocks // 2 > len(DILATIONS) * 4:
            raise ValueError("blocks must be even")

    def to_dict(self) -> dict:
        return asdict(self)


def config_for(size: str = "M", conditioning: str = "film_cos", head: str = "sigmoid") -> MaskNetConfig:
    return MaskNetConfig(conditioning=conditioning, head=head, **SIZES[size])


class ChannelNorm(nn.Module):
    def __init__(self, c: int):
        super().__init__()
        self.norm = nn.LayerNorm(c)

    def forward(self, x):
        return self.norm(x.transpose(1, 2)).transpose(1, 2)


class FiLMGen(nn.Module):
    """gamma, beta from g(e) (and, in the second half, the per-frame cosine s):
    a linear map of [g(e), s_t], initialised to the identity transform."""

    def __init__(self, cond_dim: int, c: int, with_scalar: bool):
        super().__init__()
        self.lin = nn.Linear(cond_dim, 2 * c)
        self.scalar = nn.Parameter(torch.zeros(2 * c)) if with_scalar else None
        nn.init.zeros_(self.lin.weight)
        nn.init.zeros_(self.lin.bias)
        self.c = c

    def forward(self, cond, s=None):
        gb = self.lin(cond)[:, :, None]
        if self.scalar is not None:
            if s is None:
                raise ValueError("second-half FiLM needs the cosine")
            gb = gb + self.scalar[None, :, None] * s[:, None, :]
        return 1.0 + gb[:, : self.c], gb[:, self.c:]


class DSBlock(nn.Module):
    def __init__(self, c: int, kernel: int, dilation: int, expansion: int):
        super().__init__()
        self.norm = ChannelNorm(c)
        self.dw = nn.Conv1d(c, c, kernel, padding=dilation * (kernel // 2), dilation=dilation, groups=c)
        self.pw1 = nn.Conv1d(c, expansion * c, 1)
        self.pw2 = nn.Conv1d(expansion * c, c, 1)

    def forward(self, x, mask, film=None):
        y = self.dw(self.norm(x) * mask)
        if film is not None:
            y = film[0] * y + film[1]
        return (x + self.pw2(F.gelu(self.pw1(y)))) * mask


def _interleave(z: torch.Tensor, groups: int, t: int) -> torch.Tensor:
    """[B, 2 * groups, T2] -> [B, groups, 2 * T2][..., :t]; output frame 2j + r is block r of step j."""
    b, _, t2 = z.shape
    return z.view(b, 2, groups, t2).permute(0, 2, 3, 1).reshape(b, groups, 2 * t2)[:, :, :t]


class MaskNet(nn.Module):
    def __init__(self, cfg: MaskNetConfig):
        super().__init__()
        self.cfg = cfg
        c = cfg.channels
        self.stem = nn.Conv1d(cfg.n_mels, c, 3, stride=2, padding=1)
        half = cfg.blocks // 2
        self.blocks = nn.ModuleList(DSBlock(c, cfg.kernel, DILATIONS[i % half % len(DILATIONS)], cfg.expansion)
                                    for i in range(cfg.blocks))
        if cfg.conditioning == "film_cos":
            self.proj = nn.Linear(cfg.emb_dim, cfg.proj_dim)
            self.films = nn.ModuleList(FiLMGen(cfg.proj_dim, c, with_scalar=i >= half) for i in range(cfg.blocks))
            self.cos_u = nn.Conv1d(c, cfg.cos_dim, 1)
            self.cos_v = nn.Linear(cfg.proj_dim, cfg.cos_dim)
        self.head_norm = ChannelNorm(c)
        self.mask_head = nn.Conv1d(c, 2 * cfg.n_mels, 1)
        self.aux_head = nn.Conv1d(c, 2, 1)
        nn.init.zeros_(self.mask_head.weight)
        nn.init.constant_(self.mask_head.bias, MASK_BIAS_INIT if cfg.head == "sigmoid" else LINEAR_BIAS_INIT)

    def forward(self, x: torch.Tensor, emb: torch.Tensor | None, frames_valid: torch.Tensor | None = None):
        """x [B, 128, T] Parakeet features; emb [B, D] (None only for conditioning 'none');
        frames_valid [B] valid frames (default T). -> (log_mask [B, 128, T], u_logit [B, T])."""
        b, _, t = x.shape
        cfg = self.cfg
        if frames_valid is None:
            frames_valid = torch.full((b,), t, device=x.device, dtype=torch.long)
        mask = (torch.arange(t, device=x.device)[None, :] < frames_valid.to(x.device)[:, None]).to(x.dtype)
        g = None
        if cfg.conditioning == "film_cos":
            if emb is None:
                raise ValueError("this model needs a profile embedding")
            g = F.gelu(self.proj(F.normalize(emb.to(x.dtype), dim=-1)))
        h = F.gelu(self.stem(x * mask[:, None, :]))
        t2 = h.shape[-1]
        m2 = F.max_pool1d(mask[:, None, :], kernel_size=2, stride=2, ceil_mode=True)[:, :, :t2]
        h = h * m2
        s = None
        half = cfg.blocks // 2
        for i, blk in enumerate(self.blocks):
            film = None
            if g is not None:
                if i == half:
                    s = F.cosine_similarity(self.cos_u(h), self.cos_v(g)[:, :, None], dim=1, eps=1e-6) * m2[:, 0]
                film = self.films[i](g, s if i >= half else None)
            h = blk(h, m2, film)
        h = self.head_norm(h)
        z = _interleave(self.mask_head(h), cfg.n_mels, t)
        if cfg.head == "sigmoid":
            log_mask = LOG_G_MIN * (1.0 - torch.sigmoid(z))
        else:
            log_mask = z.clamp(min=LOG_G_MIN, max=0.0)
        u_logit = _interleave(self.aux_head(h), 1, t)[:, 0]
        return log_mask * mask[:, None, :], u_logit


def param_count(model: nn.Module) -> int:
    return sum(p.numel() for p in model.parameters())


def macs_per_step(cfg: MaskNetConfig) -> dict[str, float]:
    """Analytic multiply-accumulates per 50 fps step (two 10 ms frames): convolutions,
    per-frame linear maps, FiLM application and the cosine. Excludes per-recording
    work (embedding projection, FiLM generators) and element-wise ops (reported
    as `elementwise`)."""
    c, k, e = cfg.channels, cfg.kernel, cfg.expansion
    out = {"stem": cfg.n_mels * c * 3, "blocks": cfg.blocks * (k * c + 2 * e * c * c),
           "mask_head": c * 2 * cfg.n_mels, "aux_head": c * 2}
    if cfg.conditioning == "film_cos":
        out["film_apply"] = cfg.blocks * c
        out["cos"] = c * cfg.cos_dim + 3 * cfg.cos_dim + (cfg.blocks // 2) * 2 * c
    out["elementwise"] = cfg.blocks * (2 * c + 2 * e * c) + 2 * c + 3 * 2 * cfg.n_mels
    return out


def macs_per_second(cfg: MaskNetConfig) -> float:
    return 50.0 * sum(v for k, v in macs_per_step(cfg).items() if k != "elementwise")


def per_recording_macs(cfg: MaskNetConfig) -> float:
    if cfg.conditioning == "none":
        return 0.0
    return float(cfg.emb_dim * cfg.proj_dim + cfg.blocks * cfg.proj_dim * 2 * cfg.channels + cfg.proj_dim * cfg.cos_dim)
