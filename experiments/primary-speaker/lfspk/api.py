"""The scorer contract every primary-speaker approach implements.

A scorer learns the LocalFlow user's voice from their own past dictations and,
for a new recording, says which 10 ms frames hold the user's speech. The
harness (lfspk.harness) turns those scores into a keep/drop decision per
transcribed word with one rule shared by every scorer, so approaches are
compared only on their scores.

Audio everywhere is 16 kHz mono float32 in [-1, 1], the format LocalFlow feeds
Parakeet. Frames are 10 ms (160 samples), the Parakeet front end's hop and the
frame of ParakeetSilenceCompactor: frame i covers samples [160 i, 160 (i + 1)),
and a final partial frame counts as a frame.

Product constraints the contract encodes:
- No stored audio. `enroll` and `update` see audio once; whatever a scorer
  keeps between calls lives in its Profile, which is the voiceprint LocalFlow
  would store (encrypted). `Profile.to_bytes` is exactly what would be written
  to disk, so its size and invertibility are measurable (workstream W4).
- Background adaptation. `update` folds one more dictation into the profile at
  a cost bounded by `CostReport`, with no gradient training on device unless
  the cost report says so. Enrollment and update audio is the user's own
  dictation and may itself contain other voices; a scorer must not let those
  pull the profile toward another speaker.
- Offline scoring. LocalFlow scores after the key is released, so `score` may
  look at the whole recording (non-causal).
"""

from __future__ import annotations

import math
from dataclasses import dataclass
from typing import Protocol, Sequence, runtime_checkable

import numpy as np

SAMPLE_RATE = 16_000
FRAME_SAMPLES = 160  # 10 ms


def frame_count(num_samples: int) -> int:
    """Frames covering `num_samples` samples; a final partial frame counts."""
    if num_samples < 0:
        raise ValueError("negative sample count")
    return math.ceil(num_samples / FRAME_SAMPLES)


def check_audio(audio: np.ndarray) -> np.ndarray:
    """Validate scorer input: 1-D float32, finite, within [-1, 1]."""
    if not isinstance(audio, np.ndarray) or audio.ndim != 1 or audio.dtype != np.float32:
        raise TypeError("audio must be a 1-D float32 numpy array")
    if audio.size and (not np.isfinite(audio).all() or np.abs(audio).max() > 1.0):
        raise ValueError("audio must be finite and within [-1, 1]")
    return audio


@dataclass(frozen=True)
class CostReport:
    """What a scorer would cost on device. All figures are per scorer, not per call.

    params: weights the scorer ships (excluding Parakeet itself; a scorer that
        reads Parakeet activations counts only its own head, and says so in notes).
    macs_per_audio_second: multiply-accumulates to score one second of audio.
    update_macs: multiply-accumulates for one `update` of a 10 s dictation.
    profile_bytes: size of Profile.to_bytes() for a fully enrolled profile.
    reads_parakeet_layers: Parakeet encoder layer indices the scorer reads
        (empty if it runs on audio alone). -1 means the final encoder output.
    notes: anything a reviewer needs to interpret the numbers.
    """

    params: int
    macs_per_audio_second: float
    update_macs: float
    profile_bytes: int
    reads_parakeet_layers: tuple[int, ...] = ()
    notes: str = ""


@runtime_checkable
class Profile(Protocol):
    """A scorer's learned voiceprint. Opaque to the harness."""

    def to_bytes(self) -> bytes:
        """Exactly what LocalFlow would persist (before encryption)."""
        ...


@runtime_checkable
class TargetSpeakerScorer(Protocol):
    name: str

    def enroll(self, utterances: Sequence[np.ndarray]) -> Profile:
        """Build a profile from the user's first dictations (at least one)."""
        ...

    def update(self, profile: Profile, utterance: np.ndarray) -> Profile:
        """Fold one more dictation into the profile. Must not retain the audio."""
        ...

    def score(self, profile: Profile, audio: np.ndarray) -> np.ndarray:
        """float32 array of length frame_count(len(audio)); element i in [0, 1]
        is the scorer's belief that frame i contains the user's speech. Frames
        with no speech at all should score low; frames where the user and
        someone else overlap should score high (the user is speaking)."""
        ...

    def cost(self) -> CostReport:
        ...


def check_scores(scores: np.ndarray, num_samples: int) -> np.ndarray:
    """Validate `score` output against the contract."""
    if not isinstance(scores, np.ndarray) or scores.ndim != 1 or scores.dtype != np.float32:
        raise TypeError("scores must be a 1-D float32 numpy array")
    if scores.size != frame_count(num_samples):
        raise ValueError(f"expected {frame_count(num_samples)} frames, got {scores.size}")
    if scores.size and (not np.isfinite(scores).all() or scores.min() < 0.0 or scores.max() > 1.0):
        raise ValueError("scores must be finite and within [0, 1]")
    return scores
