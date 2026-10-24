"""Training and held-out examples from W0's mixer (DESIGN section 8), train split only.

W5 renders nothing itself: every mixture is W0's `MixtureGenerator("train",
speakers=...)` with a target utterance chosen from the target speaker's mixture
pool (W3's partitions), and every profile is W3's enrollment draw from the
(overlay-corrected) bank. Unlike W3's `W0Source`, the example keeps the source
images that W5's training target needs.

Families: S0 0.2, N 0.1, S1-S4 0.175 each. N is an S1 render without its
interferers, its noise image raised by U[0, 15] dB, both components rescaled
together if the peak exceeds 0.95. Absent target with p 0.05: the profile is
another training speaker's (never a held-out one, never a mixture speaker).

Targets: T2 y* = target image + noise image; T1 y* = target image. For an
absent target, the target image is someone else's voice, so y* is the noise
image (T2) or silence (T1).

Training labels are relative to the conditioning identity c: interfering
speech at frame t = activity of any voice other than c. Present target: W0's
`interferer_active`. Absent target: `target_active | interferer_active`.
N: interferers removed, so `interferer_active` contributes nothing; the
rendered target counts only when it is absent. W0's frozen labels are not
touched.

Held-out speakers: 48 target-eligible train speakers (24 F, 24 M), first in
sha256("w5-heldout/<speaker>") order, excluded from every training role.
"""

from __future__ import annotations

import hashlib
from dataclasses import dataclass, field
from typing import Mapping, Sequence

import numpy as np
import torch

from lfspk import api as lfapi
from lfspk.pvad.enrollment import (EnrollmentBank, EnrollPolicy, SpeakerPartition, check_mixture_targets, draw_impostor,
                                   draw_profile, target_eligible)
from lfspk.pvad.w0_source import interferer_speakers

from .api import HOP, feature_frames, valid_frames
from .frontend import MelPower, ideal_log_mask, log_norm

FAMILIES = ("S0", "N", "S1", "S2", "S3", "S4")
FAMILY_WEIGHTS = (0.2, 0.1, 0.175, 0.175, 0.175, 0.175)
TARGET_KINDS = ("T2", "T1")
HELD_OUT_PER_SEX = 24
PEAK = 0.95
SUM_ATOL = 1e-5


def held_out_speakers(partitions: Mapping[str, SpeakerPartition], sex: Mapping[str, str],
                      per_sex: int = HELD_OUT_PER_SEX) -> tuple[str, ...]:
    """The 48 held-out train speakers: target-eligible, first `per_sex` of each
    sex in sha256("w5-heldout/<speaker>") order. Sorted by id."""
    order = sorted((s for s, p in partitions.items() if target_eligible(p)),
                   key=lambda s: hashlib.sha256(f"w5-heldout/{s}".encode()).hexdigest())
    out: list[str] = []
    for want in ("F", "M"):
        chosen = [s for s in order if sex.get(s) == want][:per_sex]
        if len(chosen) < per_sex:
            raise ValueError(f"only {len(chosen)} eligible {want} speakers")
        out += chosen
    return tuple(sorted(out, key=int))


def train_sex() -> dict[str, str]:
    from lfspk import splits

    return {s.id: s.sex for s in splits.speakers("train")}


@dataclass(frozen=True)
class ExamplePolicy:
    family_weights: tuple[float, ...] = FAMILY_WEIGHTS
    p_absent: float = 0.05
    p_mixed_rir: float = 0.2
    n_gain_db: tuple[float, float] = (0.0, 15.0)
    target_kind: str = "T2"
    enroll: EnrollPolicy = field(default_factory=EnrollPolicy)

    def __post_init__(self):
        w = np.asarray(self.family_weights, dtype=float)
        if w.shape != (len(FAMILIES),) or (w < 0).any() or not np.isclose(w.sum(), 1.0):
            raise ValueError("family_weights needs six non-negative weights summing to 1")
        if self.target_kind not in TARGET_KINDS:
            raise ValueError(f"target_kind must be one of {TARGET_KINDS}")


@dataclass
class Example:
    audio: np.ndarray  # mixture as the model hears it
    target: np.ndarray  # y* for the policy's target kind
    interfering: np.ndarray  # bool per contract frame, relative to the conditioning identity
    profile: np.ndarray  # float32 unit [D]
    info: dict
    target_image: np.ndarray | None = None  # the rendered target's image (as scaled in `audio`)
    noise: np.ndarray | None = None  # the noise image (as scaled in `audio`)
    labels: np.ndarray | None = None  # W0 contract labels of `audio` (N: interferers removed, so 0/1)
    meta: dict | None = None  # W0 mixture meta (N: interferers removed, `w5_family` = "N")


def example_rngs(seed: int, index: int) -> dict[str, np.random.Generator]:
    """Independent streams per example (as W3's ExampleRngs), so runs with the
    same seed see the same mixtures and absent flags whatever their target kind."""
    names = ("mix", "absent", "enroll", "gain")
    return {n: np.random.default_rng([int(seed), int(index), k, 5]) for k, n in enumerate(names)}


def identity_labels(target_active: np.ndarray, interferer_active: np.ndarray, absent: bool, family: str) -> np.ndarray:
    """Interfering speech relative to the conditioning identity (DESIGN section 8)."""
    t = np.asarray(target_active, dtype=bool)
    i = np.zeros_like(t) if family == "N" else np.asarray(interferer_active, dtype=bool)
    return (t | i) if absent else i


def check_components(m) -> None:
    """W0's limiter applies one gain to every component, so the mixture is their sum."""
    s = m.target + m.noise
    for x in m.interferers:
        s = s + x
    if np.max(np.abs(m.audio - s), initial=0.0) > SUM_ATOL:
        raise AssertionError("mixture != target + interferers + noise")


class ExampleSource:
    """example(seed, index) -> Example, a pure function of (seed, index) given
    the generator, partitions, bank and policy."""

    def __init__(self, generator, partitions: Mapping[str, SpeakerPartition], bank: EnrollmentBank,
                 targets: Sequence[str], excluded: Sequence[str], policy: ExamplePolicy, conditioned: bool = True,
                 _synthetic_test: bool = False):
        gsplit = getattr(generator, "split", None)
        if gsplit != "train" and not _synthetic_test:
            raise ValueError(f"W5 trains and calibrates on the train split only (generator split {gsplit!r})")
        self.gen = generator
        self.partitions = partitions
        self.bank = bank
        self.policy = policy
        self.excluded = frozenset(str(s) for s in excluded)
        self.conditioned = conditioned
        from lfspk.harness.mix import TARGET_SECONDS

        lo, hi = TARGET_SECONDS
        by_id = generator.corpus.utterance_by_id
        self.pools: dict[str, list[str]] = {}
        for spk in sorted(targets, key=int):
            part = partitions[spk]
            if not target_eligible(part):
                raise ValueError(f"{spk} is not target-eligible")
            if spk in self.excluded:
                raise ValueError(f"target {spk} is excluded")
            pool = sorted(u for u in part.mixture if lo <= by_id[u].seconds <= hi)
            if pool:
                self.pools[spk] = pool
        self.targets = sorted(self.pools, key=int)
        if not self.targets:
            raise ValueError("no target speakers")

    def example(self, seed: int, index: int, family: str | None = None) -> Example:
        r = example_rngs(seed, index)
        pol = self.policy
        fam = FAMILIES[int(r["mix"].choice(len(FAMILIES), p=np.asarray(pol.family_weights)))]
        if family is not None:  # fixed-family streams (stage 0, monitor, theta_b)
            fam = family
        spk = self.targets[int(r["mix"].integers(len(self.targets)))]
        pool = self.pools[spk]
        utt = pool[int(r["mix"].integers(len(pool)))]
        rseed = int(r["mix"].integers(2**62))
        mode = "mixed" if r["mix"].random() < pol.p_mixed_rir else "coherent"
        m = self.gen.render("S1" if fam == "N" else fam, rseed, target=utt, device="builtin", rir_mode=mode)
        if m.meta["target"]["utt"] != utt or str(m.meta["target"]["speaker"]) != spk:
            raise AssertionError("W0 rendered a different target than requested")
        check_mixture_targets(self.partitions[spk], [utt])
        check_components(m)
        others = interferer_speakers(m.meta)
        leaked = set(others) & self.excluded
        if leaked:
            raise AssertionError(f"excluded speakers {sorted(leaked)} appear as interferers")
        target, noise = m.target, m.noise
        if fam == "N":
            g = np.float32(10.0 ** (float(r["gain"].uniform(*pol.n_gain_db)) / 20.0))
            noise = noise * g
            mix = target + noise
            peak = float(np.max(np.abs(mix), initial=0.0))
            if peak > PEAK:
                k = np.float32(PEAK / peak)
                target, noise, mix = target * k, noise * k, (target + noise) * k
                mix = target + noise
            mix = mix.astype(np.float32)
            mixture_speakers = (spk,)
        else:
            mix = m.audio
            mixture_speakers = (spk, *others)
        absent = bool(r["absent"].random() < pol.p_absent)
        if absent:
            imp, draw = draw_impostor(self.bank, self.partitions, tuple(self.excluded | set(mixture_speakers)), pol.enroll,
                                      r["enroll"], "builtin")
            y = noise if pol.target_kind == "T2" else np.zeros_like(target)
        else:
            imp = None
            draw = draw_profile(self.bank, self.partitions[spk], "builtin", pol.enroll, r["enroll"])
            if set(draw.utts) & {utt}:
                raise AssertionError("enrollment reuses the mixture utterance")
            y = target + noise if pol.target_kind == "T2" else target
        labels = identity_labels(m.target_active, m.interferer_active, absent, fam)
        if labels.shape != (lfapi.frame_count(len(mix)),):
            raise AssertionError("label length differs from the contract frame count")
        info = {"family": fam, "speaker": spk, "utt": utt, "seed": rseed, "rir_mode": mode, "absent": absent,
                "impostor": imp, "k": draw.k, "contamination_rate": draw.contamination_rate,
                "contaminated": draw.contaminated, "matched": draw.matched,
                # only voices present in the final mixture (N removes S1's interferers; implI2-r1 #2)
                "interferers": [] if fam == "N" else list(others),
                "removed_interferers": list(others) if fam == "N" else [], "n_gain_db": None}
        if fam == "N":
            info["n_gain_db"] = float(20 * np.log10(float(g)))
        prof = draw.profile.astype(np.float32) if self.conditioned else np.zeros_like(draw.profile, dtype=np.float32)
        meta = dict(m.meta)
        w0_labels = np.asarray(m.labels, dtype=np.uint8)
        if fam == "N":
            meta["interferers"] = []
            meta["w5_family"] = "N"
            w0_labels = np.asarray(m.target_active, dtype=np.uint8)  # 1 target only, 0 none
        return Example(np.asarray(mix, dtype=np.float32), np.asarray(y, dtype=np.float32), labels, prof, info,
                       np.asarray(target, dtype=np.float32), np.asarray(noise, dtype=np.float32), w0_labels, meta)


def frame_labels(interfering: np.ndarray, num_samples: int) -> np.ndarray:
    """Contract-frame labels -> Parakeet feature frames (N // 160 + 1); frame i
    is contract frame i; frames past the contract count (at most one) are 0."""
    t = feature_frames(num_samples)
    out = np.zeros(t, dtype=np.float32)
    k = min(t, len(interfering))
    out[:k] = interfering[:k]
    return out


@torch.no_grad()
def prepare_batch(examples: Sequence[Example], mel: MelPower, crop_frames: int, rng: np.random.Generator,
                  device: str | torch.device = "cpu") -> dict[str, torch.Tensor]:
    """Features over the whole mixture first, then an even-aligned random crop
    of `crop_frames` valid frames (shorter mixtures are padded and masked).
    Returns x [B, 128, C], ideal [B, 128, C], labels [B, C], valid [B, C],
    profile [B, D]."""
    b = len(examples)
    n_max = max(len(e.audio) for e in examples)
    audio = torch.zeros(b, n_max)
    target = torch.zeros(b, n_max)
    lens = torch.tensor([len(e.audio) for e in examples])
    for i, e in enumerate(examples):
        audio[i, : len(e.audio)] = torch.from_numpy(e.audio)
        target[i, : len(e.target)] = torch.from_numpy(e.target)
    audio, target, lens = audio.to(device), target.to(device), lens.to(device)
    p_mix = mel(audio, lens)
    p_tgt = mel(target, lens)
    x = log_norm(p_mix, lens)
    ideal = ideal_log_mask(p_tgt, p_mix)
    c = int(crop_frames)
    xs = torch.zeros(b, x.shape[1], c, device=x.device)
    ids = torch.zeros(b, x.shape[1], c, device=x.device)
    lab = torch.zeros(b, c, device=x.device)
    val = torch.zeros(b, c, device=x.device)
    for i, e in enumerate(examples):
        m = valid_frames(len(e.audio))
        start = 0
        if m > c:
            start = 2 * int(rng.integers((m - c) // 2 + 1))
        stop = min(start + c, m)
        k = stop - start
        xs[i, :, :k] = x[i, :, start:stop]
        ids[i, :, :k] = ideal[i, :, start:stop]
        lab[i, :k] = torch.from_numpy(frame_labels(e.interfering, len(e.audio))[start:stop]).to(x.device)
        val[i, :k] = 1.0
    prof = torch.from_numpy(np.stack([e.profile for e in examples])).to(x.device)
    return {"x": xs, "ideal": ids, "labels": lab, "valid": val, "profile": prof}


__all__ = ["FAMILIES", "FAMILY_WEIGHTS", "held_out_speakers", "train_sex", "ExamplePolicy", "Example", "ExampleSource",
           "identity_labels", "check_components", "frame_labels", "prepare_batch", "example_rngs", "HOP"]
