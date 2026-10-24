"""Deterministic utterance selection, crops and the speech-activity rule (DESIGN 5.1).

Everything here is a pure function of utterance ids, audio arrays and a seed,
so selections never depend on iteration order or on other workstreams.
Utterance ids are LibriSpeech ids "<speaker>-<chapter>-<index>".
"""

from __future__ import annotations

import hashlib
from dataclasses import dataclass, field
from typing import Mapping, Sequence

import numpy as np

from lfspk.api import FRAME_SAMPLES, SAMPLE_RATE, frame_count

from . import SEED

ACTIVE_REL_DB = 35.0  # frame active if within this many dB of the loudest frame
ACTIVE_FLOOR_DBFS = -60.0  # ... and above this absolute level (frame RMS, dBFS)
CROP_MIN_ACTIVE = 0.5
CROP_DRAWS = 50
LENGTHS = {"full": None, "2s": 2.0, "1s": 1.0}


def rng_for(*keys: object, seed: int = SEED) -> np.random.Generator:
    """A generator seeded from the seed and the keys, independent of call order."""
    text = "|".join([str(seed), *map(str, keys)])
    return np.random.default_rng(int.from_bytes(hashlib.sha256(text.encode()).digest()[:8], "little"))


def chapter_of(utt: str) -> str:
    spk, chap, _ = utt.split("-")
    return chap


def speaker_of(utt: str) -> str:
    return utt.split("-")[0]


# --- activity ------------------------------------------------------------------------------------


def frame_db(audio: np.ndarray) -> np.ndarray:
    """RMS level in dBFS per 10 ms frame (final partial frame zero-padded)."""
    n = frame_count(audio.size)
    padded = np.zeros(n * FRAME_SAMPLES, dtype=np.float64)
    padded[: audio.size] = audio
    ms = (padded.reshape(n, FRAME_SAMPLES) ** 2).mean(1)
    return 10.0 * np.log10(np.maximum(ms, 1e-12))


def activity(audio: np.ndarray, reference_db: float | None = None) -> np.ndarray:
    """bool per 10 ms frame: speech-active by the fixed energy rule.

    reference_db defaults to the loudest frame of `audio` itself; pass the clean
    source's own maximum when labelling a source that was scaled for mixing.
    """
    db = frame_db(audio)
    if db.size == 0:
        return np.zeros(0, dtype=bool)
    ref = db.max() if reference_db is None else reference_db
    return (db >= ref - ACTIVE_REL_DB) & (db > ACTIVE_FLOOR_DBFS)


@dataclass(frozen=True)
class Crop:
    start: int  # sample index
    length: int  # samples
    active_fraction: float
    fallback: bool  # no draw reached CROP_MIN_ACTIVE; the most active draw was used


def choose_crop(audio: np.ndarray, seconds: float, rng: np.random.Generator) -> Crop:
    """One window of `seconds`, start aligned to 10 ms frames, at least half active.

    Draws uniformly among frame-aligned starts; returns the first draw meeting
    CROP_MIN_ACTIVE, else the most active of CROP_DRAWS draws. An utterance
    shorter than the window returns the whole utterance.
    """
    length = int(round(seconds * SAMPLE_RATE))
    if length % FRAME_SAMPLES:
        raise ValueError("crop length must be a whole number of 10 ms frames")
    if audio.size <= length:
        act = activity(audio)
        return Crop(0, audio.size, float(act.mean()) if act.size else 0.0, bool(not act.size or act.mean() < CROP_MIN_ACTIVE))
    act = activity(audio)
    win = length // FRAME_SAMPLES
    max_start = (audio.size - length) // FRAME_SAMPLES
    csum = np.concatenate([[0], np.cumsum(act)])
    best: tuple[float, int] | None = None
    for _ in range(CROP_DRAWS):
        s = int(rng.integers(0, max_start + 1))
        frac = float(csum[min(s + win, act.size)] - csum[s]) / win
        if frac >= CROP_MIN_ACTIVE:
            return Crop(s * FRAME_SAMPLES, length, frac, False)
        if best is None or frac > best[0]:
            best = (frac, s)
    assert best is not None
    return Crop(best[1] * FRAME_SAMPLES, length, best[0], True)


# --- train selection -----------------------------------------------------------------------------


def train_selection(utts_by_speaker: Mapping[str, Sequence[str]], per_speaker: int = 24) -> dict[str, list[str]]:
    """Up to `per_speaker` utterances per speaker, round-robin over sorted chapters,
    seeded shuffle inside each chapter. Output lists are in selection order."""
    out: dict[str, list[str]] = {}
    for spk in sorted(utts_by_speaker, key=int):
        by_chap: dict[str, list[str]] = {}
        for u in sorted(utts_by_speaker[spk]):
            if speaker_of(u) != spk:
                raise ValueError(f"{u} is not speaker {spk}")
            by_chap.setdefault(chapter_of(u), []).append(u)
        queues = []
        for chap in sorted(by_chap, key=int):
            items = list(by_chap[chap])
            rng_for("train", spk, chap).shuffle(items)
            queues.append(items)
        chosen: list[str] = []
        while len(chosen) < per_speaker and any(queues):
            for q in queues:
                if q and len(chosen) < per_speaker:
                    chosen.append(q.pop(0))
        out[spk] = chosen
    return out


# --- sessions -----------------------------------------------------------------------------------


def parse_chapters_txt(text: str) -> dict[str, str]:
    """Map chapter id -> LibriVox project id from LibriSpeech CHAPTERS.TXT.

    A project is one LibriVox recording project (often one book, one recording
    setup). It is the session unit we trust more than the chapter: chapters of
    one project may share microphone and room."""
    out: dict[str, str] = {}
    for line in text.splitlines():
        if not line.strip() or line.lstrip().startswith(";"):
            continue
        f = [x.strip() for x in line.split("|")]
        if len(f) >= 5:
            out[f[0]] = f[4]
    return out


def load_projects(root=None) -> dict[str, str]:
    from lfspk import paths

    root = paths.LIBRISPEECH if root is None else root
    return parse_chapters_txt((root / "CHAPTERS.TXT").read_text(encoding="utf-8", errors="replace"))


# --- dev verification protocol -------------------------------------------------------------------

ENROLL_MODELS = 3
ENROLL_UTTS = 3
TEST_UTTS = 20
MIN_TEST = 5  # a session class needs at least this many test utterances
SESSIONS = ("cross_project", "cross_chapter", "same_chapter")


@dataclass
class DevSpeakerPlan:
    speaker: str
    session: str  # one of SESSIONS: how test utterances relate to the enrollment chapter
    enroll_models: list[list[str]] = field(default_factory=list)  # ENROLL_MODELS lists of ENROLL_UTTS
    test: list[str] = field(default_factory=list)


def dev_plan(utts_by_speaker: Mapping[str, Sequence[str]], project_of: Mapping[str, str]) -> list[DevSpeakerPlan]:
    """Enrollment models and test utterances per dev speaker (DESIGN 5.1).

    Enrollment comes from one chapter. Test utterances come from other LibriVox
    projects when at least MIN_TEST exist (cross_project), else from other
    chapters of the same project (cross_chapter), else from the rest of the
    enrollment chapter (same_chapter). The enrollment chapter is the one with
    at least 9 utterances that leaves the most cross-project test material
    (if that is below MIN_TEST everywhere: the most other-chapter material; ties:
    the larger chapter, then the lower id).
    """
    need = ENROLL_MODELS * ENROLL_UTTS
    plans = []
    for spk in sorted(utts_by_speaker, key=int):
        utts = sorted(utts_by_speaker[spk])
        by_chap: dict[str, list[str]] = {}
        for u in utts:
            by_chap.setdefault(chapter_of(u), []).append(u)
        proj = {c: project_of[c] for c in by_chap}

        def cross_project(c):
            return [u for u in utts if proj[chapter_of(u)] != proj[c]]

        def cross_chapter(c):
            return [u for u in utts if chapter_of(u) != c and proj[chapter_of(u)] == proj[c]]

        cands = [c for c in by_chap if len(by_chap[c]) >= need]
        if not cands:
            raise ValueError(f"speaker {spk}: no chapter with {need} utterances")
        def rank(c):
            xp = len(cross_project(c))
            # cross-chapter material only matters when cross-project material is insufficient
            return (-xp, -(len(cross_chapter(c)) if xp < MIN_TEST else 0), -len(by_chap[c]), int(c))

        enroll_chap = sorted(cands, key=rank)[0]
        pool = list(by_chap[enroll_chap])
        rng_for("dev-enroll", spk).shuffle(pool)
        enroll = pool[:need]
        if len(cross_project(enroll_chap)) >= MIN_TEST:
            session, rest = "cross_project", cross_project(enroll_chap)
        elif len(cross_chapter(enroll_chap)) >= MIN_TEST:
            session, rest = "cross_chapter", cross_chapter(enroll_chap)
        else:
            session, rest = "same_chapter", pool[need:]
            if len(rest) < MIN_TEST:
                raise ValueError(f"speaker {spk}: too few test utterances")
        rest = sorted(rest)
        rng_for("dev-test", spk).shuffle(rest)
        plan = DevSpeakerPlan(spk, session)
        plan.enroll_models = [enroll[i * ENROLL_UTTS:(i + 1) * ENROLL_UTTS] for i in range(ENROLL_MODELS)]
        plan.test = rest[:TEST_UTTS]
        plans.append(plan)
    return plans


def dev_halves(strata: Mapping[str, object]) -> tuple[list[str], list[str]]:
    """Fixed seeded split of dev speakers into a selection half S and an
    evaluation half E (DESIGN 5.5), stratified by `strata` (speaker -> label;
    W2 uses (subset, sex, session class)). Choices such as the best tap are made on S
    and reported on E. Odd strata give their extra speaker alternately to E and
    S, in sorted stratum order. W0's canonical halves replace these once
    published."""
    s_half, e_half = [], []
    odd_seen = 0
    for st in sorted(set(map(str, strata.values()))):
        group = sorted((k for k, v in strata.items() if str(v) == st), key=int)
        perm = rng_for("dev-halves", st).permutation(len(group))
        k = len(group) // 2
        if len(group) % 2:
            k += odd_seen % 2  # 1st odd stratum's extra -> E, 2nd -> S, 3rd -> E, ...
            odd_seen += 1
        s_half += [group[i] for i in perm[:k]]
        e_half += [group[i] for i in perm[k:]]
    return sorted(s_half, key=int), sorted(e_half, key=int)


def dev_strata(plans, sex: Mapping[str, str], subset: Mapping[str, str]) -> dict[str, tuple[str, str, str]]:
    """(LibriSpeech subset, sex, session class) per dev speaker, from
    DevSpeakerPlans or their dicts: the strata of dev_halves."""
    out = {}
    for p in plans:
        spk = p["speaker"] if isinstance(p, Mapping) else p.speaker
        ses = p["session"] if isinstance(p, Mapping) else p.session
        out[spk] = (subset[spk], sex[spk], ses)
    return out


def crop_key(utt: str, length: str) -> tuple[str, str]:
    """RNG key for an utterance's crop of a length condition (stable across systems)."""
    return ("crop", f"{utt}:{length}")
