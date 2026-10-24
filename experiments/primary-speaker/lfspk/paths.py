"""Data and artifact locations on this host. Nothing large lives in the repo."""

from __future__ import annotations

import os
from pathlib import Path

ART = Path(os.environ.get("LFSPK_ART", "/mnt/hd/localflow-speaker"))
DATA = ART / "data"  # prepared corpora, RIRs, frozen scenario sets
RUNS = ART / "runs"  # per-workstream outputs: ART/runs/<workstream>/...

# Existing public corpora on the data disk (read-only for this project).
# One LibriSpeech root of symlinks (data/LibriSpeech): train-clean-360, dev-clean,
# test-clean and test-other from the whisper-ternary download, dev-other from the
# parakeet-ternary download (OpenSLR MD5 c8d0bcc9cca99d4f8b62fcc847357931).
LIBRISPEECH = DATA / "LibriSpeech"
MUSAN_ARCHIVE = Path("/mnt/hd/wilderness-labs-stt/noisy-dev/raw/musan/musan.tar.gz")
AMI_AUDIO = Path("/mnt/hd/wilderness-labs-stt/parakeet-ternary/audio/ami")
ICSI = Path("/mnt/hd/wilderness-labs-stt/word-boosting/learned/datasets/icsi")
PARAKEET_V2_NEMO = Path("/mnt/hd/wilderness-labs-stt/parakeet-ternary/models/parakeet-tdt-0.6b-v2/parakeet-tdt-0.6b-v2.nemo")


def require_mount() -> None:
    if not os.path.ismount("/mnt/hd"):
        raise RuntimeError("/mnt/hd is not mounted; refusing artifact writes")
