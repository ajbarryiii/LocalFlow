"""Deterministic per-speaker utterance roles for W4 (DESIGN.md section 5).

Dev speakers: a profile side with E (enrollment pool, profile = mean of
E[:k]) and A (the attacker's real audio), and a verification side H with R
(verifier reference) and T (genuine trials). The sides are separated by
LibriVox project where the speaker's projects allow it (a project is the
closest proxy for a recording setup; chapters of one project likely share
microphone and room), else by chapter, else not at all; `DevRoles.separation`
records which. Train speakers: a seeded subset of up
to 40 utterances. Everything here is a pure function of utterance ids and
seeds so it is testable without audio.
"""

from __future__ import annotations

import itertools
from dataclasses import dataclass
from typing import Sequence

import numpy as np

E_TARGET = 20  # enrollment pool size (k in {3, 10, 20} are prefixes)
E_MIN = 10  # smallest pool accepted (k = 10 is the primary condition)
R_SIZE = 5
V_MIN = 10  # verification side: R + at least 5 genuine trials T
A_SECONDS = 12.0  # attacker audio pool: utterances until this much audio


@dataclass(frozen=True)
class Utt:
    id: str  # LibriSpeech "spk-chapter-idx"
    speaker: str
    chapter: str
    num_samples: int
    project: str = ""  # LibriVox project id (CHAPTERS.TXT); "" if unknown


SEPARATIONS = ("project", "chapter", "none")


@dataclass(frozen=True)
class DevRoles:
    speaker: str
    E: tuple[str, ...]  # enrollment order (seeded); profile = E[:k]
    A: tuple[str, ...]
    R: tuple[str, ...]
    T: tuple[str, ...]
    separation: str  # "project", "chapter" or "none": what E and H never share

    @property
    def same_chapter(self) -> bool:
        return self.separation == "none"

    @property
    def H(self) -> tuple[str, ...]:
        """Held-out verification side (utility probes): R and T."""
        return self.R + self.T


def _rng(seed: int, *keys: int) -> np.random.Generator:
    return np.random.default_rng([seed, *keys])


def utt_key(utt_id: str) -> tuple[int, int, int]:
    s, c, i = utt_id.split("-")
    return int(s), int(c), int(i)


def assign_dev_roles(utts: Sequence[Utt], seed: int, sample_rate: int = 16_000) -> DevRoles:
    """Roles for one dev speaker (DESIGN.md section 5).

    Two sides that never share a session unit (project if possible, else
    chapter, else none): the profile side holds E (enrollment) and A (the
    attacker's real audio), the verification side holds R (verifier reference)
    and T (genuine trials). Profile and audio attackers therefore stand in the
    same session relation to the references. The profile side is the smallest
    feasible group set (ties: lowest sorted keys)."""
    if not utts:
        raise ValueError("speaker has no utterances")
    speakers = {u.speaker for u in utts}
    if len(speakers) != 1:
        raise ValueError("utterances from several speakers")
    spk = speakers.pop()
    utts = sorted(utts, key=lambda u: utt_key(u.id))
    a_need = A_SECONDS * sample_rate

    def split_profile_side(side: list[Utt]):
        """E as large as possible (<= E_TARGET, >= E_MIN) leaving 12 s for A."""
        order = [side[i] for i in _rng(seed, int(spk), 1).permutation(len(side))]
        for n_e in range(min(E_TARGET, len(order) - 1), E_MIN - 1, -1):
            e, rest = order[:n_e], order[n_e:]
            a, total = [], 0
            for u in rest:
                if total >= a_need:
                    break
                a.append(u)
                total += u.num_samples
            if total >= a_need:
                return e, a
        return None

    def split_verification_side(side: list[Utt]):
        if len(side) < V_MIN:
            return None
        order = [side[i] for i in _rng(seed, int(spk), 2).permutation(len(side))]
        return order[:R_SIZE], order[R_SIZE:]

    for level in ("project", "chapter"):
        key_of = (lambda u: u.project) if level == "project" else (lambda u: u.chapter)
        if level == "project" and not all(u.project for u in utts):
            continue
        groups: dict[str, list[Utt]] = {}
        for u in utts:
            groups.setdefault(key_of(u), []).append(u)
        keys = sorted(groups, key=lambda k: (len(k), k))
        feasible = []
        for r in range(1, len(keys)):
            for subset in itertools.combinations(keys, r):
                p_side = [u for u in utts if key_of(u) in subset]
                v_side = [u for u in utts if key_of(u) not in subset]
                ea, rt = split_profile_side(p_side), split_verification_side(v_side)
                if ea is not None and rt is not None:
                    # prefer the largest E (up to 20), then the smallest profile side
                    feasible.append((-len(ea[0]), len(p_side), subset, ea, rt))
        if feasible:
            _, _, _, ea, rt = min(feasible, key=lambda f: f[:3])
            return DevRoles(spk, tuple(u.id for u in ea[0]), tuple(u.id for u in ea[1]),
                            tuple(u.id for u in rt[0]), tuple(u.id for u in rt[1]), level)

    # No session separation possible: one shuffled split, keeping V_MIN aside.
    order = [utts[i] for i in _rng(seed, int(spk), 0).permutation(len(utts))]
    ea = split_profile_side(order[: max(0, len(order) - V_MIN)])
    if ea is None:
        raise ValueError(f"speaker {spk}: not enough audio for E and A")
    used = {u.id for u in ea[0] + ea[1]}
    rt = split_verification_side([u for u in order if u.id not in used])
    if rt is None:
        raise ValueError(f"speaker {spk}: too few utterances for R and T")
    return DevRoles(spk, tuple(u.id for u in ea[0]), tuple(u.id for u in ea[1]),
                    tuple(u.id for u in rt[0]), tuple(u.id for u in rt[1]), "none")


def parse_chapters_txt(text: str) -> dict[str, str]:
    """Map LibriSpeech chapter id -> LibriVox project id (CHAPTERS.TXT)."""
    out: dict[str, str] = {}
    for line in text.splitlines():
        if not line.strip() or line.lstrip().startswith(";"):
            continue
        f = [x.strip() for x in line.split("|")]
        if len(f) >= 5:
            out[f[0]] = f[4]
    return out


def select_train_utts(utt_ids: Sequence[str], speaker: str, seed: int, limit: int = 40) -> list[str]:
    """Seeded subset of up to `limit` utterances of one train speaker, sorted."""
    ids = sorted(utt_ids, key=utt_key)
    perm = _rng(seed, int(speaker)).permutation(len(ids))
    return sorted((ids[i] for i in perm[:limit]), key=utt_key)


def crop_offset(utt_id: str, num_samples: int, crop_samples: int, seed: int) -> int:
    """Seeded start of a fixed-length crop; 0 if the utterance is shorter."""
    if num_samples <= crop_samples:
        return 0
    return int(_rng(seed, *utt_key(utt_id)).integers(0, num_samples - crop_samples + 1))
