"""Training data pipeline (DESIGN.md section 5).

W3 writes no mixer: mixtures come from a `MixtureSource`, which for real runs
is an adapter over W0's scenario generator restricted to the train split. This
module turns a mixture plus an enrollment draw into a training example, batches
examples, and computes features and crops on the training device.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Iterator, Mapping, Protocol, Sequence

import numpy as np
import torch

from lfspk import api

from .enrollment import (EnrollmentBank, EnrollPolicy, SpeakerPartition, check_mixture_targets, draw_impostor,
                         draw_profile)
from .features import ParakeetFrontEnd
from .losses import classes_from_contract

IGNORE = -1


@dataclass
class Mixture:
    """One rendered mixture as the PVAD needs it.

    audio: float32 16 kHz mono. labels: contract frame labels (0..3), length
    frame_count(len(audio)). speakers: every speaker whose voice is in the
    mixture (target first; empty target means none). target_utts: the target's
    source utterance ids. channel: microphone colouring id of the target path."""

    audio: np.ndarray
    labels: np.ndarray
    target_speaker: str
    target_utts: tuple[str, ...]
    speakers: tuple[str, ...]
    scenario: str
    channel: str
    meta: dict = field(default_factory=dict)

    def __post_init__(self):
        api.check_audio(self.audio)
        if len(self.labels) != api.frame_count(len(self.audio)):
            raise ValueError("labels must have frame_count(len(audio)) entries")


class MixtureSource(Protocol):
    def sample(self, rng: np.random.Generator) -> Mixture:
        ...


@dataclass(frozen=True)
class ExamplePolicy:
    """The example distribution. It is the same for conditioned and unconditioned
    models (absent-target examples included), so ablations differ only in what
    the model is given; an unconditioned model ignores the drawn embedding."""

    enroll: EnrollPolicy = EnrollPolicy()
    p_absent_target: float = 0.1


@dataclass
class Example:
    audio: np.ndarray
    classes: np.ndarray  # int64, PVAD classes per contract frame
    emb: np.ndarray  # float32 [D]
    info: dict


@dataclass(frozen=True)
class ExampleRngs:
    """Independent streams so that the mixture, the absent-target decision and the
    enrollment draw of example i do not depend on each other's consumption: two
    policies with the same seed see the same mixtures and absent flags."""

    mix: np.random.Generator
    absent: np.random.Generator
    enroll: np.random.Generator

    @classmethod
    def for_example(cls, seed: int, index: int) -> "ExampleRngs":
        return cls(*(np.random.default_rng([seed, index, k]) for k in range(3)))


def build_example(mix: Mixture, bank: EnrollmentBank, partitions: Mapping[str, SpeakerPartition],
                  policy: ExamplePolicy, rngs: ExampleRngs) -> Example:
    info = {"scenario": mix.scenario, "channel": mix.channel, "target": mix.target_speaker}
    part = partitions.get(mix.target_speaker)
    if part is None:
        raise ValueError(f"target speaker {mix.target_speaker} has no partition")
    check_mixture_targets(part, mix.target_utts)
    absent = bool(rngs.absent.random() < policy.p_absent_target)
    if absent:
        spk, draw = draw_impostor(bank, partitions, mix.speakers, policy.enroll, rngs.enroll, mix.channel)
        info["impostor"] = spk
    else:
        draw = draw_profile(bank, part, mix.channel, policy.enroll, rngs.enroll)
        overlap = set(draw.utts) & set(mix.target_utts)
        if overlap:
            raise AssertionError(f"enrollment reuses mixture utterances {overlap}")
    info.update(k=draw.k, contamination_rate=draw.contamination_rate, contaminated=draw.contaminated,
                matched=draw.matched, level=draw.level, absent_target=absent)
    classes = classes_from_contract(mix.labels, target_present=not absent)
    return Example(mix.audio, classes, draw.profile.astype(np.float32), info)


class ExampleStream(torch.utils.data.IterableDataset):
    """Infinite stream of whole batches. Global example g * batch + j (batch g,
    position j) is a pure function of (seed, g * batch + j), whatever the number
    of DataLoader workers. DataLoader takes batches from workers round-robin, so
    worker w of W yields global batches start_step + w, start_step + w + W, ...;
    the loader's k-th batch is therefore global batch start_step + k, and a run
    resumed at step S continues the stream exactly. The DataLoader's batch_size
    must equal `batch`."""

    def __init__(self, source: MixtureSource, bank: EnrollmentBank, partitions: Mapping[str, SpeakerPartition],
                 policy: ExamplePolicy, seed: int, start_step: int = 0, batch: int = 1):
        super().__init__()
        self.source, self.bank, self.partitions, self.policy, self.seed = source, bank, partitions, policy, seed
        self.start_step, self.batch = start_step, batch

    def example(self, index: int) -> Example:
        rngs = ExampleRngs.for_example(self.seed, index)
        return build_example(self.source.sample(rngs.mix), self.bank, self.partitions, self.policy, rngs)

    def __iter__(self) -> Iterator[Example]:
        wi = torch.utils.data.get_worker_info()
        wid, nw = (wi.id, wi.num_workers) if wi is not None else (0, 1)
        g = self.start_step + wid
        while True:
            for j in range(self.batch):
                yield self.example(g * self.batch + j)
            g += nw


def collate(examples: Sequence[Example]) -> dict:
    n = max(len(e.audio) for e in examples)
    t = max(len(e.classes) for e in examples)
    audio = np.zeros((len(examples), n), np.float32)
    classes = np.full((len(examples), t), IGNORE, np.int64)
    for i, e in enumerate(examples):
        audio[i, : len(e.audio)] = e.audio
        classes[i, : len(e.classes)] = e.classes
    return {
        "audio": torch.from_numpy(audio),
        "lengths": torch.tensor([len(e.audio) for e in examples], dtype=torch.long),
        "classes": torch.from_numpy(classes),
        "emb": torch.from_numpy(np.stack([e.emb for e in examples])),
        "info": [e.info for e in examples],
    }


def prepare_batch(batch: dict, frontend: ParakeetFrontEnd, crop_frames: int, rng: np.random.Generator,
                  device: torch.device | str) -> dict:
    """Features over each whole mixture (so normalisation matches inference), then
    one random even-aligned crop of up to `crop_frames` contract frames per item."""
    audio = batch["audio"].to(device, non_blocking=True)
    lengths = batch["lengths"].to(device)
    mel = frontend(audio, lengths)  # [B, 128, N // 160 + 1]
    classes = batch["classes"].to(device)
    b = audio.shape[0]
    tc = min(crop_frames, classes.shape[1])
    out_mel = torch.zeros(b, mel.shape[1], tc, device=device)
    out_cls = torch.full((b, tc), IGNORE, dtype=torch.long, device=device)
    starts = []
    for i in range(b):
        n_frames = api.frame_count(int(batch["lengths"][i]))
        span = max(0, n_frames - tc)
        s = int(rng.integers(0, span // 2 + 1)) * 2 if span else 0
        e = min(s + tc, n_frames)
        out_mel[i, :, : e - s] = mel[i, :, s:e]
        out_cls[i, : e - s] = classes[i, s:e]
        starts.append(s)
    mask = (out_cls != IGNORE).float()
    return {"mel": out_mel, "classes": out_cls.clamp(min=0), "mask": mask,
            "emb": batch["emb"].to(device), "info": batch["info"], "starts": starts}
