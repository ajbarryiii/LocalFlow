"""Speaker splits. Fixed by LibriSpeech subset, so they never depend on a seed.

- train: train-clean-360 (921 speakers). Training, cohorts, calibration fits.
- dev: dev-clean + dev-other (73). Every choice: thresholds, hyperparameters,
  model picks. dev-other was added so selection and reporting halves each have
  enough cross-project speakers.
- test: test-clean + test-other (73). SEALED. Only the orchestrator's final
  comparison runs on it, once per frozen approach. Do not score, listen to or
  tune on test speakers during development.

Target users and their interferers in a mixture always come from the same split,
and a speaker never interferes with themself.

Auxiliary split, outside SPLIT_SUBSETS so code that iterates the main splits
never picks it up:

- clone_eval: train-clean-100 (251 speakers, disjoint from every split above).
  Added 2026-10-21 by owner decision, ONLY as extra target speakers for W4's
  voiceprint cloning-risk evaluation, so its risk bound can resolve tiers below
  "moderate". Never used for training, cohorts, calibration, attacker fitting
  or any choice. Pretrained embedders trained on LibriSpeech training subsets
  (TitaNet) may have seen these speakers; W4's primary embedder does not.
"""

from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path

from . import paths

SPLIT_SUBSETS = {
    "train": ("train-clean-360",),
    "dev": ("dev-clean", "dev-other"),
    "test": ("test-clean", "test-other"),
}
AUX_SUBSETS = {
    "clone_eval": ("train-clean-100",),
}


@dataclass(frozen=True)
class Speaker:
    id: str
    sex: str  # "F" or "M", from SPEAKERS.TXT
    subset: str


def parse_speakers_txt(text: str) -> dict[str, tuple[str, str]]:
    """Map speaker id -> (sex, subset) from LibriSpeech SPEAKERS.TXT."""
    out: dict[str, tuple[str, str]] = {}
    for line in text.splitlines():
        if not line.strip() or line.lstrip().startswith(";"):
            continue
        fields = [f.strip() for f in line.split("|")]
        if len(fields) < 3:
            continue
        out[fields[0]] = (fields[1], fields[2])
    return out


def speakers(split: str, root: Path = paths.LIBRISPEECH) -> list[Speaker]:
    """Speakers of a split (main or auxiliary), sorted by id, taken from the
    extracted directories."""
    subsets = SPLIT_SUBSETS.get(split) or AUX_SUBSETS.get(split)
    if subsets is None:
        raise ValueError(f"unknown split {split!r}")
    meta = parse_speakers_txt((root / "SPEAKERS.TXT").read_text(encoding="utf-8", errors="replace"))
    found: list[Speaker] = []
    for subset in subsets:
        for d in sorted((root / subset).iterdir(), key=lambda p: int(p.name)):
            if d.is_dir():
                sex, listed = meta[d.name]
                if listed != subset:
                    raise ValueError(f"speaker {d.name} listed under {listed}, found in {subset}")
                found.append(Speaker(d.name, sex, subset))
    return sorted(found, key=lambda s: int(s.id))


def utterances(speaker: Speaker, root: Path = paths.LIBRISPEECH) -> list[Path]:
    """The speaker's FLAC files, sorted."""
    return sorted((root / speaker.subset / speaker.id).glob("*/*.flac"))
