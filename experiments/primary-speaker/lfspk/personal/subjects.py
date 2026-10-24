"""Pilot subjects, scoring interferers, the control pairing and the base pins (DESIGN 1, 2.1, 3).

Subjects: the cross_project speakers among W5's 48 held-out train speakers,
11 per sex, first in sha256("w6-pilot/<speaker>") order (all 11 M qualify;
F takes the first 11 of 15). Scoring interferers: the other 26 held-out
speakers; they never tune anything. Control donor of A: the next subject of
the same sex in pilot order (cyclic), a same-sex derangement.
"""

from __future__ import annotations

import hashlib
from typing import Mapping

PILOT = {"F": ("2775", "1335", "6120", "5290", "8677", "1061", "2592", "5012", "6519", "4116", "3967"),
         "M": ("639", "1456", "2929", "5239", "5386", "8011", "497", "7688", "1025", "439", "119")}
PER_SEX = 11
N_TUNE = 10  # k = 10 tuning dictations (headline condition)
MAX_DICTATIONS = 40  # W3 bank utterances per speaker (the rest serve the drift diagnostic only)

# Full pinned SHA-256 of the W5 base checkpoints (DESIGN 1, r1 m7).
BASES = {
    "V0-s0": "a3d5a6e081d3dd090f3aedf7561d3a74f712cfb3f2e855795d9b08d63667a942",
    "V0u-s0": "7090b127b7ea730abc529a2ad5905b884bca0cc112239d356bb2f5a1f2f6549f",
    "VB-s0": "726910270bba8ef9ca3038379536923d802f6ad63fbbc2ae309ece21dcad54d5",
    "VBu-s0": "0662ca0c59e80d347405cd22ab6d1cea97f376336d7e0d54e4674cdab5642e07",
}
ARMS = {"A-V0": ("V0-s0", "V0u-s0"), "A-VB": ("VB-s0", "VBu-s0")}


def _h(s: str) -> str:
    return hashlib.sha256(s.encode()).hexdigest()


def pilot_order() -> tuple[str, ...]:
    """All 22 subjects: F in pilot order, then M in pilot order."""
    return PILOT["F"] + PILOT["M"]


def sex_of(speaker: str) -> str:
    for sx, members in PILOT.items():
        if speaker in members:
            return sx
    raise KeyError(f"{speaker} is not a pilot subject")


def control_donor(speaker: str) -> str:
    """B(A): the next same-sex subject in pilot order, cyclically."""
    members = PILOT[sex_of(speaker)]
    return members[(members.index(speaker) + 1) % len(members)]


def select_pilot(levels: Mapping[str, str], sex: Mapping[str, str], held: tuple[str, ...]) -> dict[str, tuple[str, ...]]:
    """The selection rule (DESIGN 2.1) from partition levels and sexes."""
    out = {}
    for sx in ("F", "M"):
        cands = sorted((s for s in held if sex[s] == sx and levels[s] == "cross_project"),
                       key=lambda s: _h(f"w6-pilot/{s}"))
        if len(cands) < PER_SEX:
            raise ValueError(f"only {len(cands)} cross_project {sx} held-out speakers")
        out[sx] = tuple(cands[:PER_SEX])
    return out


def held_out() -> tuple[str, ...]:
    from lfspk.extract.overlay import held_out as w5_held

    return tuple(w5_held())


def verify_pilot() -> dict:
    """Recompute the pilot from W5's held-out set and the partitions; refuse a mismatch."""
    from lfspk.extract.data import train_sex
    from lfspk.pvad.enrollment import librispeech_partitions

    parts = librispeech_partitions("train")
    held = held_out()
    got = select_pilot({s: parts[s].level for s in held}, train_sex(), held)
    if got != PILOT:
        raise RuntimeError(f"pilot list differs from the registered one: {got}")
    return {"held_out": held, "pilot": got}


def scoring_interferers(held: tuple[str, ...] | None = None) -> tuple[str, ...]:
    held = held if held is not None else held_out()
    pilot = set(pilot_order())
    if not pilot <= set(held):
        raise RuntimeError("a pilot subject is not held out")
    out = tuple(sorted((s for s in held if s not in pilot), key=int))
    if len(out) != len(held) - len(pilot):
        raise RuntimeError("scoring interferer pool has the wrong size")
    return out


def train_pool(held: tuple[str, ...] | None = None) -> list[str]:
    """Train speakers outside the 48 held-out: the bank's (and the dictation renders') generator pool."""
    from lfspk import splits

    hs = set(held if held is not None else held_out())
    return [s.id for s in splits.speakers("train") if s.id not in hs]


def lists_sha256() -> str:
    """Identity of the subject lists and the pairing."""
    txt = ";".join(f"{s}>{control_donor(s)}" for s in pilot_order())
    return _h(txt)


__all__ = ["PILOT", "PER_SEX", "N_TUNE", "MAX_DICTATIONS", "BASES", "ARMS", "pilot_order", "sex_of", "control_donor",
           "select_pilot", "held_out", "verify_pilot", "scoring_interferers", "train_pool", "lists_sha256"]
