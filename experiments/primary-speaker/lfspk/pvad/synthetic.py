"""Synthetic stand-ins for tests and smoke runs: tone "speakers", a toy mixer, a
toy embedder and a toy enrollment bank. Nothing here is used for real results.

A synthetic speaker has a fundamental frequency and a spectral tilt; an
utterance is voiced bursts of harmonics separated by pauses. The toy embedder
reads the speaker parameters back from the audio's spectrum crudely, so the
conditioning signal is learnable but imperfect.
"""

from __future__ import annotations

import hashlib
from dataclasses import dataclass

import numpy as np
from scipy.signal import lfilter

from lfspk import api

from .data import Mixture
from .enrollment import EnrollmentBank, SpeakerPartition, bank_utterances, build_partitions, unit

SR = api.SAMPLE_RATE


@dataclass(frozen=True)
class ToySpeaker:
    id: str
    f0: float
    tilt: float  # dB per harmonic


def toy_speakers(n: int, seed: int = 0) -> list[ToySpeaker]:
    rng = np.random.default_rng(seed)
    return [ToySpeaker(str(1000 + i), float(rng.uniform(90, 260)), float(rng.uniform(-6, -1))) for i in range(n)]


def _utt_rng(utt_id: str) -> np.random.Generator:
    return np.random.default_rng(int(hashlib.sha256(utt_id.encode()).hexdigest()[:16], 16))


def toy_utterance(spk: ToySpeaker, utt_id: str, seconds: float = 3.0) -> tuple[np.ndarray, np.ndarray]:
    """(audio, active) with active a per-sample bool mask."""
    rng = _utt_rng(utt_id)
    n = int(seconds * SR)
    audio = np.zeros(n, np.float32)
    active = np.zeros(n, bool)
    t = 0
    while t < n:
        t += int(rng.uniform(0.05, 0.4) * SR)
        dur = int(rng.uniform(0.2, 0.7) * SR)
        e = min(n, t + dur)
        if e <= t:
            break
        tt = np.arange(e - t) / SR
        f0 = spk.f0 * (1 + 0.05 * np.sin(2 * np.pi * rng.uniform(1, 4) * tt))
        phase = 2 * np.pi * np.cumsum(f0) / SR
        sig = np.zeros(e - t)
        for h in range(1, 12):
            if h * spk.f0 > 7000:
                break
            sig += 10 ** (spk.tilt * (h - 1) / 20) * np.sin(h * phase)
        env = np.hanning(e - t)
        audio[t:e] += (0.1 * sig * env).astype(np.float32)
        active[t:e] = True
        t = e
    return audio, active


def frame_activity(active: np.ndarray) -> np.ndarray:
    n = api.frame_count(len(active))
    pad = np.zeros(n * api.FRAME_SAMPLES, bool)
    pad[: len(active)] = active
    return pad.reshape(n, api.FRAME_SAMPLES).mean(axis=1) >= 0.5


TOY_CHAPTER_PROJECT = {"0": "pA", "1": "pA", "2": "pB"}
TOY_CHANNELS = ("toy-mic", "toy-headset")


def toy_partitions(speakers: list[ToySpeaker], utts_per_speaker: int = 60) -> dict[str, SpeakerPartition]:
    utts = {s.id: [toy_utt_id(s, i) for i in range(utts_per_speaker)] for s in speakers}
    return build_partitions(utts, TOY_CHAPTER_PROJECT)


def toy_utt_id(spk: ToySpeaker, i: int) -> str:
    return f"{spk.id}-{i % 3}-{i}"  # three "chapters", two "projects"


def _headset(a: np.ndarray) -> np.ndarray:
    """Toy channel: a one-pole low-pass."""
    return lfilter([0.4], [1.0, -0.6], a).astype(np.float32)


class ToySource:
    """Mixtures of one target (from its mixture pool) and at most one interferer."""

    def __init__(self, speakers: list[ToySpeaker], partitions: dict[str, SpeakerPartition], seconds: float = 4.0,
                 p_single: float = 0.2, sir_db: tuple[float, float] = (-3.0, 3.0)):
        self.speakers = speakers
        self.partitions = partitions
        self.seconds = seconds
        self.p_single = p_single
        self.sir_db = sir_db

    def sample(self, rng: np.random.Generator) -> Mixture:
        ti = int(rng.integers(len(self.speakers)))
        tgt = self.speakers[ti]
        pool = sorted(self.partitions[tgt.id].mixture)
        tu = pool[int(rng.integers(len(pool)))]
        a, act_t = toy_utterance(tgt, tu, self.seconds)
        speakers = (tgt.id,)
        act_i = np.zeros_like(act_t)
        scenario = "S0"
        if rng.random() >= self.p_single:
            oi = int(rng.integers(len(self.speakers) - 1))
            oi = oi + (oi >= ti)
            other = self.speakers[oi]
            ou = sorted(self.partitions[other.id].mixture | self.partitions[other.id].enroll)
            b, act_i = toy_utterance(other, ou[int(rng.integers(len(ou)))], self.seconds)
            sir = rng.uniform(*self.sir_db)
            pa = np.sqrt(np.mean(a[act_t] ** 2) + 1e-12)
            pb = np.sqrt(np.mean(b[act_i] ** 2) + 1e-12)
            a = a + b * (pa / pb) * 10 ** (-sir / 20)
            speakers = (tgt.id, other.id)
            scenario = "S4"
        a = a + rng.normal(0, 1e-3, a.shape)
        a = np.clip(a, -1, 1).astype(np.float32)
        ft, fi = frame_activity(act_t), frame_activity(act_i)
        labels = (ft & ~fi) * 1 + (~ft & fi) * 2 + (ft & fi) * 3
        return Mixture(a, labels.astype(np.int8), tgt.id, (tu,), speakers, scenario, TOY_CHANNELS[0])


class ToyEmbedder:
    """Unit vector from a crude spectral summary (a fixed random projection of the
    log power spectrum of the louder half of the frames)."""

    name = "toy"
    dim = 16
    params = 16 * 129
    weights_sha256 = "0" * 64

    def __init__(self, seed: int = 0):
        rng = np.random.default_rng(seed)
        self.proj = rng.normal(size=(self.dim, 129)).astype(np.float32)

    def embed(self, audio: np.ndarray) -> np.ndarray:
        x = np.asarray(audio, np.float32)
        n = len(x) // 256 * 256
        if n == 0:
            return unit(np.ones(self.dim, np.float32))
        fr = x[:n].reshape(-1, 256) * np.hanning(256)
        p = np.abs(np.fft.rfft(fr, axis=1)) ** 2
        energy = p.sum(axis=1)
        sel = p[energy >= np.quantile(energy, 0.5)]
        spec = np.log(sel.mean(axis=0) + 1e-8)
        spec = spec - spec.mean()
        return unit(self.proj @ spec.astype(np.float32))

    def embed_batch(self, audios):
        return np.stack([self.embed(a) for a in audios]).astype(np.float32)


def toy_bank(speakers: list[ToySpeaker], partitions: dict[str, SpeakerPartition], embedder: ToyEmbedder,
             per_speaker: int = 12) -> EnrollmentBank:
    """Every bank utterance under both toy channels, clean and contaminated (another
    toy speaker at 0 dB)."""
    rows, spk, utt, ch, cont = [], [], [], [], []
    for si, s in enumerate(speakers):
        other = speakers[(si + 1) % len(speakers)]
        for u in bank_utterances(partitions[s.id], per_speaker):
            a, _ = toy_utterance(s, u, 3.0)
            b, _ = toy_utterance(other, toy_utt_id(other, 0), 3.0)
            for channel in TOY_CHANNELS:
                for contaminated in (False, True):
                    x = a + b if contaminated else a
                    x = _headset(x) if channel == "toy-headset" else x
                    rows.append(embedder.embed(x.astype(np.float32)))
                    spk.append(s.id), utt.append(u), ch.append(channel), cont.append(contaminated)
    return EnrollmentBank(np.stack(rows), np.array(spk), np.array(utt), np.array(ch), np.array(cont),
                          embedder.name, embedder.weights_sha256)
