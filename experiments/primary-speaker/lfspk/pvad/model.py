"""The personal VAD network (DESIGN.md section 4.2).

Input: Parakeet log-mel [B, 128, T] at 100 fps, a unit speaker embedding
[B, D_e] (ignored when conditioning is "none"), and a frame mask [B, T].
Output: logits [B, 3, T] at 100 fps over (ns, tss, ntss).

Only convolutions, LayerNorm, GELU and elementwise ops, so Core ML can place
everything on the Neural Engine; cost per second of audio is independent of the
recording length.
"""

from __future__ import annotations

from dataclasses import asdict, dataclass

import torch
import torch.nn.functional as F
from torch import nn

NS, TSS, NTSS = 0, 1, 2
CONDITIONINGS = ("none", "concat", "film", "film_cos")
DILATIONS = (1, 3, 9, 27)


@dataclass(frozen=True)
class PVADConfig:
    channels: int = 72
    blocks: int = 8
    kernel: int = 5
    expansion: int = 2
    n_mels: int = 128
    emb_dim: int = 192
    proj_dim: int = 64  # D_g
    cos_dim: int = 32  # D_p
    conditioning: str = "film_cos"

    def __post_init__(self):
        if self.conditioning not in CONDITIONINGS:
            raise ValueError(f"conditioning must be one of {CONDITIONINGS}")
        if self.blocks < 2 or self.blocks % 2:
            raise ValueError("blocks must be even and >= 2")
        if self.kernel % 2 != 1:
            raise ValueError("kernel must be odd")

    def to_dict(self) -> dict:
        return asdict(self)


SIZES = {
    "S": dict(channels=48, blocks=8),
    "M": dict(channels=72, blocks=8),
    "L": dict(channels=96, blocks=8),
}


def config_for(size: str, conditioning: str = "film_cos", emb_dim: int = 192) -> PVADConfig:
    return PVADConfig(conditioning=conditioning, emb_dim=emb_dim, **SIZES[size])


class ChannelNorm(nn.Module):
    """LayerNorm over channels of a [B, C, T] tensor."""

    def __init__(self, c: int):
        super().__init__()
        self.norm = nn.LayerNorm(c)

    def forward(self, x):
        return self.norm(x.transpose(1, 2)).transpose(1, 2)


class FiLMGen(nn.Module):
    """gamma, beta [B, C, 1] or [B, C, T] from a conditioning vector (and an optional per-frame scalar).

    Initialised to the identity transform (gamma = 1, beta = 0)."""

    def __init__(self, cond_dim: int, c: int, with_scalar: bool):
        super().__init__()
        self.lin = nn.Linear(cond_dim, 2 * c)
        self.scalar = nn.Parameter(torch.zeros(2 * c)) if with_scalar else None
        nn.init.zeros_(self.lin.weight)
        nn.init.zeros_(self.lin.bias)
        self.c = c

    def forward(self, cond: torch.Tensor, s: torch.Tensor | None = None):
        gb = self.lin(cond)[:, :, None]  # [B, 2C, 1]
        if self.scalar is not None and s is not None:
            gb = gb + self.scalar[None, :, None] * s[:, None, :]  # [B, 2C, T]
        gamma, beta = gb[:, : self.c], gb[:, self.c:]
        return 1.0 + gamma, beta


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
            gamma, beta = film
            y = gamma * y + beta
        y = self.pw2(F.gelu(self.pw1(y)))
        return (x + y) * mask


class PVAD(nn.Module):
    def __init__(self, cfg: PVADConfig):
        super().__init__()
        self.cfg = cfg
        c = cfg.channels
        cond = cfg.conditioning
        stem_in = cfg.n_mels + (cfg.proj_dim if cond == "concat" else 0)
        self.stem = nn.Conv1d(stem_in, c, 3, stride=2, padding=1)
        self.blocks = nn.ModuleList(
            DSBlock(c, cfg.kernel, DILATIONS[i % (cfg.blocks // 2) % len(DILATIONS)], cfg.expansion)
            for i in range(cfg.blocks))
        if cond != "none":
            self.proj = nn.Linear(cfg.emb_dim, cfg.proj_dim)
        if cond in ("film", "film_cos"):
            half = cfg.blocks // 2
            self.films = nn.ModuleList(
                FiLMGen(cfg.proj_dim, c, with_scalar=(cond == "film_cos" and i >= half)) for i in range(cfg.blocks))
        if cond == "film_cos":
            self.cos_u = nn.Conv1d(c, cfg.cos_dim, 1)
            self.cos_v = nn.Linear(cfg.proj_dim, cfg.cos_dim)
        self.head_norm = ChannelNorm(c)
        self.head = nn.Conv1d(c, 3, 1)

    def forward(self, mel: torch.Tensor, emb: torch.Tensor | None, mask: torch.Tensor | None = None,
                return_cos: bool = False):
        """mel [B, 128, T]; emb [B, D_e] or None; mask [B, T] (1 = valid frame). -> logits [B, 3, T]."""
        b, _, t = mel.shape
        cfg = self.cfg
        if mask is None:
            mask = torch.ones(b, t, device=mel.device, dtype=mel.dtype)
        mask = mask.to(mel.dtype)
        g = None
        if cfg.conditioning != "none":
            if emb is None:
                raise ValueError("this model needs an embedding")
            g = F.gelu(self.proj(F.normalize(emb.to(mel.dtype), dim=-1)))
        x = mel * mask[:, None, :]
        if cfg.conditioning == "concat":
            x = torch.cat([x, g[:, :, None].expand(b, g.shape[1], t) * mask[:, None, :]], dim=1)
        x = F.gelu(self.stem(x))
        t2 = x.shape[-1]
        m2 = F.max_pool1d(mask[:, None, :], kernel_size=2, stride=2, ceil_mode=True)[:, :, :t2]  # [B,1,T2]
        x = x * m2
        s = None
        half = cfg.blocks // 2
        for i, blk in enumerate(self.blocks):
            if cfg.conditioning == "film_cos" and i == half:
                u = self.cos_u(x)
                v = self.cos_v(g)
                s = F.cosine_similarity(u, v[:, :, None], dim=1, eps=1e-6) * m2[:, 0]  # [B, T2]
            film = self.films[i](g, s) if cfg.conditioning in ("film", "film_cos") else None
            x = blk(x, m2, film)
        logits = self.head(self.head_norm(x))  # [B, 3, T2]
        # nearest x2 upsampling by expand + reshape: its backward is a plain sum
        # (deterministic on CUDA, unlike repeat_interleave's index_add)
        logits = logits[..., None].expand(*logits.shape, 2).reshape(b, 3, 2 * t2)[:, :, :t]
        if return_cos:
            return logits, s
        return logits


def param_count(model: nn.Module) -> int:
    return sum(p.numel() for p in model.parameters())


def macs_per_frame_pair(cfg: PVADConfig) -> dict[str, float]:
    """Analytic multiply-accumulates for one 50 fps output step (two 10 ms input frames).

    Counts convolutions, linear maps applied per frame, FiLM application and the
    cosine. Excludes per-recording work (the embedding projection and FiLM
    generators run once per recording) and nonlinearities/normalisation (a few
    ops per element, reported separately as `elementwise`)."""
    c, k, e = cfg.channels, cfg.kernel, cfg.expansion
    stem_in = cfg.n_mels + (cfg.proj_dim if cfg.conditioning == "concat" else 0)
    out = {
        "stem": stem_in * c * 3,
        "blocks": cfg.blocks * (k * c + 2 * e * c * c),
        "head": c * 3,
    }
    if cfg.conditioning in ("film", "film_cos"):
        out["film_apply"] = cfg.blocks * c
    if cfg.conditioning == "film_cos":
        out["cos"] = c * cfg.cos_dim + 3 * cfg.cos_dim + (cfg.blocks // 2) * 2 * c
    out["elementwise"] = cfg.blocks * (2 * c + 2 * e * c) + 2 * c  # LayerNorm, GELU, residual
    return out


def macs_per_second(cfg: PVADConfig) -> float:
    """MACs to score one second of audio (50 output steps), excluding `elementwise`."""
    parts = macs_per_frame_pair(cfg)
    return 50.0 * sum(v for k, v in parts.items() if k != "elementwise")


def per_recording_macs(cfg: PVADConfig) -> float:
    if cfg.conditioning == "none":
        return 0.0
    m = cfg.emb_dim * cfg.proj_dim
    if cfg.conditioning in ("film", "film_cos"):
        m += cfg.blocks * cfg.proj_dim * 2 * cfg.channels
    if cfg.conditioning == "film_cos":
        m += cfg.proj_dim * cfg.cos_dim
    return float(m)
