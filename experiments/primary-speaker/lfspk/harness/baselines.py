"""Baseline scorers (DESIGN.md section 8). Factories follow the harness
convention `module:callable` -> TargetSpeakerScorer:

    lfspk.harness.baselines:keep_everything
    lfspk.harness.baselines:energy_gate
    oracle            (built into the evaluator: it needs the frame labels)
"""

from __future__ import annotations

import math
from dataclasses import dataclass
from typing import Sequence

import numpy as np

from ..api import FRAME_SAMPLES, CostReport, check_audio, frame_count


@dataclass(frozen=True)
class EmptyProfile:
    def to_bytes(self) -> bytes:
        return b""


class KeepEverything:
    """Scores every frame 1: filtering removes nothing (the unfiltered system)."""

    name = "keep-everything"

    def enroll(self, utterances: Sequence[np.ndarray]) -> EmptyProfile:
        return EmptyProfile()

    def update(self, profile: EmptyProfile, utterance: np.ndarray) -> EmptyProfile:
        return profile

    def score(self, profile: EmptyProfile, audio: np.ndarray) -> np.ndarray:
        check_audio(audio)
        return np.ones(frame_count(audio.size), dtype=np.float32)

    def cost(self) -> CostReport:
        return CostReport(0, 0.0, 0.0, 0, (), "constant score")


def gate_frames(audio: np.ndarray) -> np.ndarray:
    """Exact port of LocalFlow ParakeetSilenceCompactor.isSpeech
    (Sources/Parakeet/ParakeetSilenceCompactor.swift): per 10 ms frame, a level
    in dB re full scale against an adaptive noise floor that drops at once and,
    outside speech, rises 0.03 dB per frame, clamped to [-70, -40] dB; speech
    starts 10 dB over the floor and continues 6 dB over it. Digital silence is
    silence; non-finite frames are speech. A final partial frame is a frame."""
    floor_lo, floor_hi = -70.0, -40.0
    rise, onset, release = 0.03, 10.0, 6.0
    floor = floor_hi
    speaking = False
    n = frame_count(audio.size)
    out = np.zeros(n, dtype=bool)
    x = audio.astype(np.float64)
    for i in range(n):
        seg = x[i * FRAME_SAMPLES : (i + 1) * FRAME_SAMPLES]
        energy = float(np.dot(seg, seg))
        if not math.isfinite(energy):
            speaking = True
            out[i] = True
            continue
        if energy <= 0.0:
            speaking = False
            continue
        level = 10.0 * math.log10(energy / seg.size)
        speaking = level > floor + (release if speaking else onset)
        nxt = level if level < floor else (floor if speaking else floor + rise)
        floor = min(max(nxt, floor_lo), floor_hi)
        out[i] = speaking
    return out


class EnergyGate:
    """LocalFlow's silence gate as a scorer: 1 on frames it calls speech."""

    name = "energy-gate"

    def enroll(self, utterances: Sequence[np.ndarray]) -> EmptyProfile:
        return EmptyProfile()

    def update(self, profile: EmptyProfile, utterance: np.ndarray) -> EmptyProfile:
        return profile

    def score(self, profile: EmptyProfile, audio: np.ndarray) -> np.ndarray:
        check_audio(audio)
        return gate_frames(audio).astype(np.float32)

    def cost(self) -> CostReport:
        return CostReport(0, 100 * 165.0, 0.0, 0, (), "160 MACs plus a log per 10 ms frame; no profile")


def keep_everything() -> KeepEverything:
    return KeepEverything()


def energy_gate() -> EnergyGate:
    return EnergyGate()
