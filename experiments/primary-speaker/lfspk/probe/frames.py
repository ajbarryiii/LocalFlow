"""Stage 3 building blocks (DESIGN 6): profile-conditioned frame heads, mixture
plans and profile construction. Pure parts are torch/numpy only (no NeMo).
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Callable, Mapping, Sequence

import numpy as np
import torch
from torch import nn

from .backend import Backend, enrollment_model
from .select import chapter_of, rng_for, speaker_of

HIDDEN = 256
KERNEL = 5
TRAIN_MAX_SECONDS = 10.0  # target crop; a turn-taking mixture can reach twice this


class FrameHead(nn.Module):
    """Linear(in->H); FiLM from the profile (or a learned constant if
    unconditioned); GELU; Conv1d(H->H, k=5) over time; GELU; Linear(H->1).

    forward(x [B, T, in], profile [B, P] or None, lengths [B] or None) ->
    logits [B, T]. With lengths, hidden frames at t >= lengths[b] are zeroed
    before the temporal convolution, so valid outputs do not depend on how
    much padding the batch adds.
    """

    def __init__(self, in_dim: int, profile_dim: int, conditioned: bool = True, hidden: int = HIDDEN):
        super().__init__()
        self.conditioned = conditioned
        self.inp = nn.Linear(in_dim, hidden)
        if conditioned:
            self.film = nn.Linear(profile_dim, 2 * hidden)
        else:
            self.film_const = nn.Parameter(torch.zeros(2 * hidden))
        self.conv = nn.Conv1d(hidden, hidden, KERNEL, padding=KERNEL // 2)
        self.out = nn.Linear(hidden, 1)
        self.act = nn.GELU()

    def forward(self, x: torch.Tensor, profile: torch.Tensor | None,
                lengths: torch.Tensor | None = None) -> torch.Tensor:
        h = self.inp(x)
        if self.conditioned:
            if profile is None:
                raise ValueError("conditioned head needs a profile")
            gb = self.film(profile)
        else:
            gb = self.film_const.expand(x.size(0), -1)
        gamma, beta = gb.chunk(2, dim=-1)
        h = self.act(h * (1 + gamma[:, None, :]) + beta[:, None, :])
        if lengths is not None:
            valid = torch.arange(h.size(1), device=h.device)[None, :] < lengths[:, None]
            h = h * valid[..., None]
        h = self.act(self.conv(h.transpose(1, 2)).transpose(1, 2))
        return self.out(h).squeeze(-1)


def masked_bce(logits: torch.Tensor, target: torch.Tensor, lengths: torch.Tensor) -> torch.Tensor:
    """Mean soft-label BCE over valid frames (t < lengths[b])."""
    mask = torch.arange(logits.size(1), device=logits.device)[None, :] < lengths[:, None]
    loss = nn.functional.binary_cross_entropy_with_logits(logits, target, reduction="none")
    return (loss * mask).sum() / mask.sum().clamp_min(1)


def stack_logmel(feats: torch.Tensor, enc_len: torch.Tensor, steps: int) -> torch.Tensor:
    """Normalised log-mel [B, 128, T10] -> [B, steps, 1024]: 8 consecutive 10 ms
    frames per 80 ms encoder frame (frame j = 10 ms frames 8j..8j+7, zero-padded)."""
    b, f, t = feats.shape
    need = steps * 8
    x = feats if t >= need else nn.functional.pad(feats, (0, need - t))
    x = x[:, :, :need].reshape(b, f, steps, 8).permute(0, 2, 3, 1).reshape(b, steps, 8 * f)
    mask = torch.arange(steps, device=feats.device)[None, :] < enc_len[:, None]
    return x * mask[..., None]


# --- speakers, halves, plans ---------------------------------------------------------------------


def halves(speakers: Sequence[str]) -> tuple[list[str], list[str]]:
    """Seeded split of train speakers: A fits the stage-3 back end, B supplies
    the heads' training mixtures, so profiles on train are not sharpened by a
    back end that saw the same speakers (matches dev, whose speakers it never saw)."""
    s = sorted(speakers, key=int)
    perm = rng_for("stage3-halves").permutation(len(s))
    k = (len(s) + 1) // 2
    a = sorted((s[i] for i in perm[:k]), key=int)
    b = sorted((s[i] for i in perm[k:]), key=int)
    return a, b


@dataclass(frozen=True)
class MixPlan:
    target: str  # utterance id
    interferer: str
    enroll: tuple[str, ...]  # 3 utterance ids of the target speaker, disjoint from `target`
    same_sex: bool
    key: str  # rng key for mixing


def choose_enroll(target_utt: str, pool: Sequence[str], rng: np.random.Generator, k: int = 3) -> tuple[str, ...]:
    """k utterances of the target's speaker other than target_utt, from other
    chapters when at least k exist."""
    others = sorted(u for u in pool if u != target_utt)
    other_ch = [u for u in others if chapter_of(u) != chapter_of(target_utt)]
    cand = other_ch if len(other_ch) >= k else others
    if len(cand) < k:
        raise ValueError(f"not enough enrollment utterances for {target_utt}")
    return tuple(sorted(rng.choice(cand, k, replace=False).tolist()))


def train_plan(i: int, seed: int, selection: Mapping[str, Sequence[str]], speakers: Sequence[str],
               sex: Mapping[str, str]) -> MixPlan:
    """Mixture i of the training stream for `seed` (index-seeded, order-free)."""
    rng = rng_for("stage3-train", seed, i)
    spk = speakers[int(rng.integers(len(speakers)))]
    target = selection[spk][int(rng.integers(len(selection[spk])))]
    want_same = bool(rng.random() < 0.5)
    pool = [s for s in speakers if s != spk and (sex[s] == sex[spk]) == want_same]
    ispk = pool[int(rng.integers(len(pool)))]
    interferer = selection[ispk][int(rng.integers(len(selection[ispk])))]
    enroll = choose_enroll(target, selection[spk], rng)
    return MixPlan(target, interferer, enroll, sex[ispk] == sex[spk], f"train|{seed}|{i}")


def dev_plans(plans: Sequence[Mapping], sex: Mapping[str, str],
              halves: Sequence[Sequence[str]] | None = None) -> list[MixPlan]:
    """One mixture per dev test utterance; even-numbered mixtures of a speaker
    use a same-sex interferer, odd ones any other speaker. Enrollment = model 0.
    With `halves` (select.dev_halves), interferers come from the target's own
    half, so the halves share no speaker and selection on S stays independent
    of evaluation on E."""
    by_spk = {p["speaker"]: p for p in plans}
    half_of = {}
    for h in halves or [list(by_spk)]:
        for s in h:
            half_of[s] = tuple(h)
    out = []
    for p in plans:
        spk = p["speaker"]
        for j, utt in enumerate(p["test"]):
            rng = rng_for("stage3-dev", utt)
            pool = [s for s in half_of[spk] if s != spk and (j % 2 == 1 or sex[s] == sex[spk])]
            ispk = pool[int(rng.integers(len(pool)))]
            itest = by_spk[ispk]["test"]
            interferer = itest[int(rng.integers(len(itest)))]
            out.append(MixPlan(utt, interferer, tuple(p["enroll_models"][0]), sex[ispk] == sex[spk], f"dev|{utt}"))
    return out


def check_plan(p: MixPlan) -> None:
    spk = speaker_of(p.target)
    if speaker_of(p.interferer) == spk:
        raise ValueError("interferer is the target speaker")
    if any(speaker_of(u) != spk for u in p.enroll) or p.target in p.enroll:
        raise ValueError("enrollment must be other utterances of the target speaker")


# --- profiles ------------------------------------------------------------------------------------


class ProfileTable:
    """Per-tap back-end embeddings of full-length utterances; profile = renormalised
    mean of the enrollment utterances' embeddings (backend.enrollment_model)."""

    def __init__(self, embeddings: np.ndarray, utt_index: Mapping[str, int]):
        self.emb = embeddings  # [taps, N, k] float32, length-normalised
        self.idx = dict(utt_index)

    @classmethod
    def build(cls, feats: np.ndarray, rows: Mapping[str, int], backends: Sequence[Backend]) -> "ProfileTable":
        """feats [taps, N, d] pooled features; rows: utt -> row of its full-length item."""
        utts = sorted(rows)
        r = [rows[u] for u in utts]
        emb = np.stack([be.transform(np.asarray(feats[t][r], dtype=np.float64)).astype(np.float32)
                        for t, be in enumerate(backends)])
        return cls(emb, {u: i for i, u in enumerate(utts)})

    def profile(self, enroll: Sequence[str]) -> np.ndarray:
        """[taps, k] float32."""
        rows = [self.idx[u] for u in enroll]
        return np.stack([enrollment_model(self.emb[t, rows]) for t in range(self.emb.shape[0])]).astype(np.float32)


def frame_stats(feats: np.ndarray, rows: Sequence[int]) -> tuple[np.ndarray, np.ndarray]:
    """Per-tap frame mean/std [taps, D] from pooled (mean, std) features [taps, N, 2D]
    of full utterances, weighting utterances equally: mu = E[m],
    var = E[s^2 + m^2] - mu^2."""
    d = feats.shape[2] // 2
    mus, sds = [], []
    for t in range(feats.shape[0]):
        x = np.asarray(feats[t][list(rows)], dtype=np.float64)
        m, s = x[:, :d], x[:, d:]
        mu = m.mean(0)
        var = (s ** 2 + m ** 2).mean(0) - mu ** 2
        mus.append(mu)
        sds.append(np.sqrt(np.maximum(var, 1e-8)))
    return np.stack(mus).astype(np.float32), np.stack(sds).astype(np.float32)


def crop_target(audio: np.ndarray, rng: np.random.Generator, max_seconds: float = TRAIN_MAX_SECONDS) -> np.ndarray:
    n = int(max_seconds * 16000)
    if audio.size <= n:
        return audio
    s = int(rng.integers(0, (audio.size - n) // 160 + 1)) * 160
    return audio[s:s + n]


def make_example(plan: MixPlan, load: Callable[[str], np.ndarray], train: bool):
    """Audio + 10 ms labels for a plan (deterministic in plan.key)."""
    from .simplemix import mix

    check_plan(plan)
    rng = rng_for("stage3-mix", plan.key)
    target = load(plan.target)
    if train:
        target = crop_target(target, rng)
    return mix(target, load(plan.interferer), rng)
