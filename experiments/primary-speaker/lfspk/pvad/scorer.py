"""PVADScorer: the W3 `TargetSpeakerScorer` (DESIGN.md sections 4 and 8).

Profile = count n, the running mean of the user's unit dictation embeddings
(float32 [D]) and, with recalibration on, a running mean of one statistic per
dictation. `score` runs the PVAD on Parakeet features with the profile's unit
mean as the conditioning vector and returns softmax P(tss) per 10 ms frame.

Update rules:
- "mean": add the whole dictation's embedding.
- "gated": embed only the frames the current PVAD scores P(tss) >= gate; skip
  the update when fewer than `min_gated_s` seconds pass the gate.
"""

from __future__ import annotations

import struct
from dataclasses import dataclass
from typing import Sequence

import numpy as np
import torch

from lfspk import api

from .enrollment import unit
from .features import ParakeetFrontEnd
from .losses import p_target
from .model import PVAD, PVADConfig, macs_per_second, param_count, per_recording_macs

_MAGIC = b"LFW3"
_VERSION = 1


@dataclass
class PVADProfile:
    """count: dictations folded in; mean: running mean of unit embeddings [D];
    recal_n / recal_mean: dictations and running mean of the per-dictation
    recalibration statistic (logit P(tss) 10th percentile over confident frames)."""

    count: int
    mean: np.ndarray
    recal_n: int = 0
    recal_mean: float = 0.0

    def embedding(self) -> np.ndarray:
        return unit(self.mean)

    def to_bytes(self) -> bytes:
        m = np.ascontiguousarray(self.mean, dtype="<f4")
        head = struct.pack("<4sBHIIf", _MAGIC, _VERSION, m.size, self.count, self.recal_n, self.recal_mean)
        return head + m.tobytes()

    @classmethod
    def from_bytes(cls, b: bytes) -> "PVADProfile":
        size = struct.calcsize("<4sBHIIf")
        magic, ver, d, count, rn, rm = struct.unpack("<4sBHIIf", b[:size])
        if magic != _MAGIC or ver != _VERSION:
            raise ValueError("not a W3 profile")
        mean = np.frombuffer(b[size: size + 4 * d], dtype="<f4").astype(np.float32)
        if mean.size != d:
            raise ValueError("truncated profile")
        return cls(int(count), mean, int(rn), float(rm))


def _logit(p: np.ndarray) -> np.ndarray:
    p = np.clip(p.astype(np.float64), 1e-6, 1 - 1e-6)
    return np.log(p) - np.log1p(-p)


def recal_statistic(p_tss: np.ndarray, gate: float = 0.5, q: float = 0.10) -> float | None:
    """10th percentile of logit P(tss) over frames with P(tss) >= gate; None if under 100 frames."""
    sel = p_tss[p_tss >= gate]
    if sel.size < 100:
        return None
    return float(np.quantile(_logit(sel), q))


def fit_recal_population(scorer: "PVADScorer", users: Sequence[tuple["PVADProfile", Sequence[np.ndarray]]]) -> float:
    """Population value of the recalibration statistic: mean over users of the
    mean per-dictation statistic of their own clean dictations, scored with their
    own profile. Fit on train-split speakers only."""
    per_user = []
    for profile, dictations in users:
        emb = profile.embedding() if scorer.cfg.conditioning != "none" else None
        stats = [s for s in (recal_statistic(scorer._p_tss(emb, d), scorer.gate) for d in dictations) if s is not None]
        if stats:
            per_user.append(float(np.mean(stats)))
    if not per_user:
        raise ValueError("no dictation had enough confident target frames")
    return float(np.mean(per_user))


class PVADScorer:
    def __init__(self, model: PVAD, embedder, name: str = "pvad", update_rule: str = "mean",
                 gate: float = 0.5, min_gated_s: float = 1.0, recal_population: float | None = None,
                 device: str = "cpu", embedder_params: int | None = None, embedder_macs_per_s: float | None = None):
        if update_rule not in ("mean", "gated"):
            raise ValueError("update_rule must be 'mean' or 'gated'")
        self.model = model.eval().to(device)
        self.cfg: PVADConfig = model.cfg
        self.embedder = embedder
        self.name = name
        self.update_rule = update_rule
        self.gate = gate
        self.min_gated_s = min_gated_s
        self.recal_population = recal_population
        self.device = device
        self.frontend = ParakeetFrontEnd().to(device)
        self.embedder_params = embedder_params
        self.embedder_macs_per_s = embedder_macs_per_s
        if self.cfg.conditioning != "none" and embedder is not None and embedder.dim != self.cfg.emb_dim:
            raise ValueError(f"embedder dim {embedder.dim} != model emb_dim {self.cfg.emb_dim}")

    # -- core ---------------------------------------------------------------------------------------------

    @torch.no_grad()
    def _posteriors(self, emb: np.ndarray | None, audio: np.ndarray) -> np.ndarray:
        """[frame_count, 3] softmax posteriors (ns, tss, ntss), before recalibration."""
        n = api.frame_count(len(audio))
        if n == 0:
            return np.zeros((0, 3), np.float32)
        x = torch.from_numpy(np.ascontiguousarray(audio))[None].to(self.device)
        mel = self.frontend(x)[:, :, :n]
        e = None
        if self.cfg.conditioning != "none":
            e = torch.from_numpy(emb.astype(np.float32))[None].to(self.device)
        logits = self.model(mel, e)
        return torch.softmax(logits.float(), dim=1)[0].T.cpu().numpy().astype(np.float32)

    @torch.no_grad()
    def log_odds(self, profile: "PVADProfile", audio: np.ndarray) -> np.ndarray:
        """float64 target log-odds per frame from the logits (diagnostics; no
        recalibration), the frame-metric score representation (metrics.py)."""
        from .metrics import logit_from_logits

        api.check_audio(audio)
        n = api.frame_count(len(audio))
        if n == 0:
            return np.zeros(0, np.float64)
        x = torch.from_numpy(np.ascontiguousarray(audio))[None].to(self.device)
        mel = self.frontend(x)[:, :, :n]
        cond = self._cond(profile)
        e = None if cond is None else torch.from_numpy(cond.astype(np.float32))[None].to(self.device)
        z = self.model(mel, e).float()[0].T.cpu().numpy().astype(np.float64)
        return logit_from_logits(z)

    def _p_tss(self, emb, audio) -> np.ndarray:
        return self._posteriors(emb, audio)[:, 1]

    def _embed(self, audio: np.ndarray) -> np.ndarray:
        return unit(self.embedder.embed(audio))

    def _gated_audio(self, p_tss: np.ndarray, audio: np.ndarray) -> np.ndarray | None:
        keep = p_tss >= self.gate
        if keep.sum() * api.FRAME_SAMPLES < self.min_gated_s * api.SAMPLE_RATE:
            return None
        mask = np.repeat(keep, api.FRAME_SAMPLES)[: len(audio)]
        return np.ascontiguousarray(audio[mask], dtype=np.float32)

    def _needs_pass(self) -> bool:
        return self.update_rule == "gated" or self.recal_population is not None

    def _fold(self, profile: PVADProfile, e: np.ndarray) -> PVADProfile:
        n = profile.count + 1
        mean = profile.mean + (unit(e) - profile.mean) / n
        return PVADProfile(n, mean.astype(np.float32), profile.recal_n, profile.recal_mean)

    def _fold_recal(self, profile: PVADProfile, p_tss: np.ndarray | None) -> PVADProfile:
        if self.recal_population is None or p_tss is None:
            return profile
        stat = recal_statistic(p_tss, self.gate)
        if stat is None:
            return profile
        rn = profile.recal_n + 1
        rm = profile.recal_mean + (stat - profile.recal_mean) / rn
        return PVADProfile(profile.count, profile.mean, rn, float(rm))

    def _cond(self, profile: PVADProfile) -> np.ndarray | None:
        return profile.embedding() if self.cfg.conditioning != "none" else None

    # -- contract -----------------------------------------------------------------------------------------

    def enroll(self, utterances: Sequence[np.ndarray]) -> PVADProfile:
        """Plain mean of the dictations' embeddings; with the gated rule, each
        dictation is then re-embedded from the frames that mean's PVAD scores as
        the user. Recalibration statistics come from the same PVAD pass."""
        if len(utterances) < 1:
            raise ValueError("enroll needs at least one dictation")
        for u in utterances:
            api.check_audio(u)
        if self.cfg.conditioning == "none":
            prof = PVADProfile(len(utterances), np.zeros(1, np.float32))
        else:
            embs = [self._embed(u) for u in utterances]
            prof = PVADProfile(len(embs), np.mean(embs, axis=0).astype(np.float32))
        if not self._needs_pass():
            return prof
        cond = self._cond(prof)
        passes = [self._p_tss(cond, u) for u in utterances]
        if self.update_rule == "gated" and self.cfg.conditioning != "none":
            regated = [self._embed(g) for g in (self._gated_audio(p, u) for p, u in zip(passes, utterances))
                       if g is not None]
            if regated:
                prof = PVADProfile(len(regated), np.mean(regated, axis=0).astype(np.float32))
        for p in passes:
            prof = self._fold_recal(prof, p)
        return prof

    def update(self, profile: PVADProfile, utterance: np.ndarray) -> PVADProfile:
        """At most one PVAD pass (with the pre-update profile), shared by gating and
        recalibration, and at most one embedder pass."""
        api.check_audio(utterance)
        p = self._p_tss(self._cond(profile), utterance) if self._needs_pass() else None
        new = profile
        if self.cfg.conditioning != "none":
            if self.update_rule == "gated":
                g = self._gated_audio(p, utterance)
                if g is not None:
                    new = self._fold(profile, self._embed(g))
            else:
                new = self._fold(profile, self._embed(utterance))
        return self._fold_recal(new, p)

    def score(self, profile: PVADProfile, audio: np.ndarray) -> np.ndarray:
        api.check_audio(audio)
        p = self._p_tss(self._cond(profile), audio)
        if self.recal_population is not None and profile.recal_n > 0:
            shift = self.recal_population - profile.recal_mean
            p = 1.0 / (1.0 + np.exp(-(_logit(p) + shift)))
        return np.clip(p, 0.0, 1.0).astype(np.float32)

    def _embedder_cost(self) -> tuple[int, float]:
        if self.cfg.conditioning == "none":
            return 0, 0.0
        params = self.embedder_params if self.embedder_params is not None else getattr(self.embedder, "params", None)
        if params is None:
            raise ValueError("embedder parameter count unknown: pass embedder_params")
        if self.embedder_macs_per_s is None:
            raise ValueError("embedder MACs per second unknown: pass embedder_macs_per_s")
        return int(params), float(self.embedder_macs_per_s)

    def cost(self) -> api.CostReport:
        """params: PVAD plus the embedder it ships for enroll/update. update_macs for
        a 10 s dictation: one embedder pass over at most 10 s, plus one PVAD pass
        when the gated rule or recalibration is on."""
        pvad_params = param_count(self.model)
        emb_params, emb_macs = self._embedder_cost()
        d = self.cfg.emb_dim if self.cfg.conditioning != "none" else 1
        prof_bytes = len(PVADProfile(1, np.zeros(d, np.float32)).to_bytes())
        update = 10 * emb_macs
        if self._needs_pass():
            update += 10 * macs_per_second(self.cfg) + per_recording_macs(self.cfg)
        return api.CostReport(
            params=pvad_params + emb_params,
            macs_per_audio_second=macs_per_second(self.cfg),
            update_macs=float(update),
            profile_bytes=prof_bytes,
            reads_parakeet_layers=(),
            notes=(f"PVAD-only params {pvad_params}; embedder params {emb_params} "
                   f"({getattr(self.embedder, 'name', 'none')}, {emb_macs:.3g} MACs/s), run only in enroll/update; "
                   "update_macs counts the embedder trunk only (its front end and per-call overhead excluded), "
                   "so it is a lower-bound estimate. "
                   "Scoring MACs exclude the log-mel front end, shared with Parakeet "
                   "(about 4.3M MACs/s if computed separately), and per-recording FiLM generation "
                   f"({per_recording_macs(self.cfg):.0f} MACs)."),
        )
