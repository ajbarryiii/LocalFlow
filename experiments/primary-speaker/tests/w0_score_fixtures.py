"""A scorer that loads a "checkpoint" file, at construction or lazily on the
first score() (tests of the score content identity; synthetic data only)."""

from __future__ import annotations

from pathlib import Path

import numpy as np

from lfspk.api import CostReport, frame_count


class _Prof:
    def to_bytes(self) -> bytes:
        return b"p"


class FileScorer:
    name = "file-scorer"

    def __init__(self, checkpoint: str, lazy: str = "0", mode: str = "rb", fail: str = "0", optional: str = ""):
        self.path = Path(checkpoint)
        self.mode, self.fail = mode, fail == "1"
        self.weights = None if lazy == "1" else self._read()
        if optional:  # an optional file whose failed read is caught (not a dependency)
            try:
                with open(optional, "rb") as f:
                    f.read()
            except OSError:
                pass

    def _read(self) -> bytes:
        if self.mode == "osrdwr":  # os.open with O_RDWR
            import os

            fd = os.open(self.path, os.O_RDWR)
            try:
                return os.read(fd, 1 << 20)
            finally:
                os.close(fd)
        with open(self.path, self.mode) as f:  # "rb" or "r+b"
            return f.read()

    def _w(self) -> bytes:
        if self.weights is None:
            self.weights = self._read()
        return self.weights

    def enroll(self, utterances):
        return _Prof()

    def update(self, profile, utterance):
        return profile

    def score(self, profile, audio):
        if self.fail:
            raise RuntimeError("fixture scorer fails on purpose")
        level = (self._w()[0] % 7) / 7.0
        return np.full(frame_count(audio.size), level, np.float32)

    def cost(self) -> CostReport:
        return CostReport(params=1, macs_per_audio_second=1.0, update_macs=0.0, profile_bytes=1, reads_parakeet_layers=(), notes="fixture")


def make(**kwargs) -> FileScorer:
    return FileScorer(**kwargs)
