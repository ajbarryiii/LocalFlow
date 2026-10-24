"""Canonical dev halves: A for selection, B for reporting (DESIGN.md section 8).

Fixed and deterministic. Speakers are stratified by LibriSpeech subset (dev-clean / dev-other), sex and session class
(the weakest enrollment relation among the first 10 dictations of their
speaker plan: cross_project, same_project_cross_chapter, same_chapter; a
speaker whose stream is shorter than 10 takes the class of the dictations it
has). Within each stratum speakers are ordered by a stable hash and dealt
alternately; the first deal of each stratum alternates between A and B so the
halves stay within one speaker of each other. Frozen dev mixtures never cross
halves: a target's interferers and contamination talkers come from its own half.
"""

from __future__ import annotations

from functools import lru_cache

from .util import stable_int

HALVES = ("A", "B")
CLASS_K = 10


def assign_halves(speakers: dict[str, tuple[str, ...]]) -> dict[str, str]:
    """speakers: id -> stratum key (subset, sex, session class). Returns id -> 'A' or 'B'."""
    strata: dict[tuple[str, ...], list[str]] = {}
    for spk, key in speakers.items():
        strata.setdefault(key, []).append(spk)
    out: dict[str, str] = {}
    flip = 0
    for key in sorted(strata):
        members = sorted(strata[key], key=lambda s: stable_int("dev-half", s))
        for i, spk in enumerate(members):
            out[spk] = HALVES[(i + flip) % 2]
        flip = (flip + len(members)) % 2
    return out


@lru_cache(maxsize=1)
def dev_halves() -> dict[str, tuple[str, ...]]:
    """{'A': speaker ids, 'B': speaker ids} for the dev split."""
    from .mix import MixtureGenerator

    gen = MixtureGenerator("dev")
    keys = {}
    for spk in gen.corpus.speakers:
        plan = gen.speaker_plan(spk)
        keys[spk] = (gen.corpus.subset[spk], gen.corpus.sex[spk], plan.relation_at(CLASS_K))
    a = assign_halves(keys)
    return {h: tuple(sorted((s for s, v in a.items() if v == h), key=int)) for h in HALVES}


def half_of(speaker: str) -> str:
    h = dev_halves()
    return "A" if speaker in h["A"] else "B" if speaker in h["B"] else ""
