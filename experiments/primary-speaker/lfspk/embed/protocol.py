"""Stage A intrinsic protocol: enrollment / test pools per speaker and seeded
test-segment placement. Deterministic; see DESIGN.md, Stage A."""

from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path

import numpy as np

from .. import splits
from ..api import FRAME_SAMPLES, SAMPLE_RATE
from .audio import GateConfig, frame_energy_db, speech_gate

SEGMENT_SECONDS = (0.5, 1.0, 1.5, 2.0)
SEEDS = (0, 1, 2)
MAX_ENROLL = 30


def utt_id(path: Path) -> str:
    return path.stem


def chapter_of(path: Path) -> str:
    return path.parent.name


def chapter_projects(root: Path = splits.paths.LIBRISPEECH) -> dict[str, str]:
    """LibriVox project id of every chapter, from CHAPTERS.TXT. Chapters of one
    project were usually recorded in the same setting (microphone, room)."""
    out = {}
    for line in (root / "CHAPTERS.TXT").read_text(encoding="utf-8", errors="replace").splitlines():
        if not line.strip() or line.lstrip().startswith(";"):
            continue
        fields = [f.strip() for f in line.split("|")]
        if len(fields) >= 5:
            out[fields[0]] = fields[4]
    return out


# Session relation between a speaker's enrollment and test pools, most to least independent.
CROSS_PROJECT, SAME_PROJECT, SAME_CHAPTER = "cross_project", "same_project", "same_chapter"


@dataclass(frozen=True)
class SpeakerPlan:
    speaker: splits.Speaker
    enroll: tuple[Path, ...]  # ordered; profile from the first k
    test: tuple[Path, ...]
    relation: str  # CROSS_PROJECT, SAME_PROJECT or SAME_CHAPTER


def plan_speaker(speaker: splits.Speaker, utterances: list[Path], projects: dict[str, str]) -> SpeakerPlan:
    """Test pool = the LibriVox project of the speaker's last chapter when the
    speaker has another project (enroll from the other projects); else the
    last chapter (same project); else, with one chapter, the utterances after
    the first MAX_ENROLL. Enrollment keeps chapter then utterance order and at
    most MAX_ENROLL utterances."""
    utts = sorted(utterances, key=lambda p: (int(chapter_of(p)), p.stem))
    chapters = sorted({chapter_of(p) for p in utts}, key=int)
    proj = {c: projects[c] for c in chapters}
    if len(set(proj.values())) >= 2:
        test_proj = proj[chapters[-1]]
        enroll = [p for p in utts if proj[chapter_of(p)] != test_proj][:MAX_ENROLL]
        test = [p for p in utts if proj[chapter_of(p)] == test_proj]
        relation = CROSS_PROJECT
    elif len(chapters) >= 2:
        enroll = [p for p in utts if chapter_of(p) != chapters[-1]][:MAX_ENROLL]
        test = [p for p in utts if chapter_of(p) == chapters[-1]]
        relation = SAME_PROJECT
    else:
        enroll, test, relation = utts[:MAX_ENROLL], utts[MAX_ENROLL:], SAME_CHAPTER
    if not enroll or not test:
        raise ValueError(f"speaker {speaker.id}: empty enrollment or test pool")
    return SpeakerPlan(speaker, tuple(enroll), tuple(test), relation)


def plan(split: str = "dev") -> list[SpeakerPlan]:
    if split == "test":
        raise PermissionError("the test split is sealed")
    projects = chapter_projects()
    return [plan_speaker(s, splits.utterances(s), projects) for s in splits.speakers(split)]


# Placement uses the gate without its p95 cap: a noise-dominated clip then keeps
# a noise-floor threshold instead of marking all frames as speech.
PLACEMENT_GATE = GateConfig(peak_gap_db=None)


def place_segment(audio: np.ndarray, seconds: float, rng: np.random.Generator,
                  min_speech: float = 0.5) -> tuple[int, int, bool]:
    """(start, length, ok): a segment of `seconds` starting on a 10 ms frame
    boundary, drawn uniformly among the starts whose speech fraction under
    PLACEMENT_GATE is at least `min_speech` (ok = True); if no start
    qualifies, the most speech-dense start (ok = False, a fallback the caller
    counts). A clip no longer than the segment is returned whole (ok = True)."""
    length = int(round(seconds * SAMPLE_RATE))
    if audio.size <= length:
        return 0, audio.size, True
    gate = speech_gate(frame_energy_db(audio), PLACEMENT_GATE).astype(np.float64)
    last_start = (audio.size - length) // FRAME_SAMPLES  # frame-aligned starts keep the segment inside the clip
    span = (length + FRAME_SAMPLES - 1) // FRAME_SAMPLES
    csum = np.r_[0.0, np.cumsum(gate)]
    starts = np.arange(last_start + 1)
    ends = np.minimum(starts + span, gate.size)
    frac = (csum[ends] - csum[starts]) / (ends - starts)
    ok = np.nonzero(frac >= min_speech)[0]
    if ok.size:
        return int(ok[int(rng.integers(ok.size))]) * FRAME_SAMPLES, length, True
    return int(np.argmax(frac)) * FRAME_SAMPLES, length, False


def segment_rng(seed: int, utterance: str, seconds: float) -> np.random.Generator:
    """Independent stream per (seed, utterance, length), stable across runs."""
    key = [seed, int(round(seconds * 1000))] + [int(x) for x in utterance.split("-")]
    return np.random.default_rng(key)


def dev_half(speakers: list[splits.Speaker]) -> dict[str, str]:
    """Speaker id -> "A" or "B": W0's canonical dev halves
    (`lfspk.harness.halves`, stratified by sex and session class), so every
    workstream selects on the same half A and reports on the same half B."""
    from ..harness.halves import half_of

    out = {s.id: half_of(s.id) for s in speakers}
    if not all(v in ("A", "B") for v in out.values()):
        raise ValueError("dev_half is defined for dev speakers only")
    return out


def cohort_role(speaker_id: str) -> str:
    """Train speakers are split once, by a stable hash, into "cohort" (their
    embeddings are the shipped AS-norm cohort) and "fit" (head training and
    gate calibration). No identity is in both, so normalisation statistics
    during fitting never contain the fitted speaker, as on dev."""
    from ..harness.util import stable_int

    return "cohort" if stable_int("w1-cohort-role", speaker_id) % 2 == 0 else "fit"
