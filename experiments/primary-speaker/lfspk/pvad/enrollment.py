"""Enrollment embeddings for training (DESIGN.md section 5) and the profile rule.

The profile is the L2-normalised mean of per-dictation unit embeddings. The
scorer's `enroll` uses the same rule, so the embeddings the PVAD sees in
training are distributed like those it sees on device.

Every train speaker's utterances are split once, deterministically, into an
**enrollment pool** and a **mixture pool** (`partition_speaker`). The split is
by LibriVox project when the speaker has more than one (a project is probably
one microphone and room), else by chapter, else by utterance; the level used is
recorded. Mixture targets must come from the mixture pool and enrollment
dictations from the enrollment pool; both are checked, never silently relaxed.

Training draws enrollment dictations from a precomputed `EnrollmentBank`: one
entry per (utterance, channel, contaminated) variant, where a variant is a
rendering of that utterance as a dictation under a microphone channel, either
clean (room noise only) or contaminated with another train speaker.
"""

from __future__ import annotations

import hashlib
from dataclasses import dataclass, field
from pathlib import Path
from typing import Mapping, Sequence

import numpy as np

LEVELS = ("cross_project", "same_project_cross_chapter", "same_chapter")


def unit(v: np.ndarray, eps: float = 1e-12) -> np.ndarray:
    v = np.asarray(v, dtype=np.float32)
    n = np.linalg.norm(v, axis=-1, keepdims=True)
    return (v / np.maximum(n, eps)).astype(np.float32)


def mean_profile(embeddings: np.ndarray) -> np.ndarray:
    """[k, D] unit embeddings -> unit [D]: normalised mean of the normalised rows."""
    e = np.asarray(embeddings, dtype=np.float32)
    if e.ndim != 2 or e.shape[0] < 1:
        raise ValueError("need [k >= 1, D] embeddings")
    return unit(unit(e).mean(axis=0))


def _h(s: str) -> str:
    return hashlib.sha256(s.encode()).hexdigest()


def utterance_chapter(utt_id: str) -> str:
    """LibriSpeech 'spk-chapter-idx' -> 'chapter'."""
    parts = utt_id.split("-")
    if len(parts) != 3:
        raise ValueError(f"not a LibriSpeech utterance id: {utt_id!r}")
    return parts[1]


def parse_chapters_txt(text: str) -> dict[str, str]:
    """LibriSpeech CHAPTERS.TXT -> chapter id -> LibriVox project id."""
    out: dict[str, str] = {}
    for line in text.splitlines():
        if not line.strip() or line.lstrip().startswith(";"):
            continue
        f = [x.strip() for x in line.split("|")]
        if len(f) >= 5:
            out[f[0]] = f[4]
    return out


@dataclass(frozen=True)
class SpeakerPartition:
    speaker: str
    level: str  # one of LEVELS
    enroll: frozenset
    mixture: frozenset


def partition_speaker(speaker: str, utt_ids: Sequence[str], chapter_project: Mapping[str, str]) -> SpeakerPartition:
    """Deterministic enrollment / mixture split of one speaker's utterances.

    Units are projects (if the speaker has >= 2), else chapters (if >= 2), else
    single utterances. Units are visited in sha256(speaker/unit) order and each
    goes to the pool with fewer utterances so far (ties to the mixture pool), so
    both pools are non-empty whenever there are >= 2 units."""
    utts = sorted(set(utt_ids))
    if len(utts) < 2:
        raise ValueError(f"speaker {speaker} needs at least two utterances")
    for u in utts:
        if not u.startswith(f"{speaker}-"):
            raise ValueError(f"{u} is not speaker {speaker}'s")
    chapters = {u: utterance_chapter(u) for u in utts}
    missing = sorted({c for c in chapters.values() if c not in chapter_project})
    if missing:
        raise ValueError(f"chapters without a project: {missing[:5]}")
    projects = {u: chapter_project[c] for u, c in chapters.items()}
    if len(set(projects.values())) >= 2:
        level, key = "cross_project", projects
    elif len(set(chapters.values())) >= 2:
        level, key = "same_project_cross_chapter", chapters
    else:
        level, key = "same_chapter", {u: u for u in utts}
    units: dict[str, list[str]] = {}
    for u in utts:
        units.setdefault(key[u], []).append(u)
    pools = {"mixture": [], "enroll": []}
    for unit_id in sorted(units, key=lambda x: _h(f"{speaker}/{x}")):
        dest = "enroll" if len(pools["enroll"]) < len(pools["mixture"]) else "mixture"
        pools[dest].extend(units[unit_id])
    return SpeakerPartition(speaker, level, frozenset(pools["enroll"]), frozenset(pools["mixture"]))


def build_partitions(utts_by_speaker: Mapping[str, Sequence[str]],
                     chapter_project: Mapping[str, str]) -> dict[str, SpeakerPartition]:
    return {s: partition_speaker(s, u, chapter_project) for s, u in sorted(utts_by_speaker.items())}


def bank_utterances(partition: SpeakerPartition, per_speaker: int = 40) -> list[str]:
    """Deterministic choice of up to `per_speaker` utterances from the enrollment
    pool, round-robin over its chapters (chapters and utterances in sha256 order)."""
    by_ch: dict[str, list[str]] = {}
    for u in partition.enroll:
        by_ch.setdefault(utterance_chapter(u), []).append(u)
    chapters = sorted(by_ch, key=lambda c: _h(f"{partition.speaker}/{c}"))
    queues = [sorted(by_ch[c], key=_h) for c in chapters]
    out: list[str] = []
    i = 0
    while len(out) < per_speaker and any(queues):
        q = queues[i % len(queues)]
        if q:
            out.append(q.pop(0))
        i += 1
    return sorted(out)


@dataclass
class EnrollmentBank:
    """Precomputed dictation embeddings. Row i: emb[i] for utterance utt[i] under
    channel channel[i], contaminated[i] telling whether another voice was mixed in."""

    emb: np.ndarray  # float32 or float16 [N, D], unit rows
    speaker: np.ndarray  # str [N]
    utt: np.ndarray  # str [N]
    channel: np.ndarray  # str [N]
    contaminated: np.ndarray  # bool [N]
    embedder: str = ""
    embedder_sha256: str = ""
    _index: dict = field(default_factory=dict, repr=False)
    _channels: tuple = field(default=(), repr=False)
    _speakers: tuple = field(default=(), repr=False)
    _utts: dict = field(default_factory=dict, repr=False)

    def __post_init__(self):
        n = len(self.emb)
        for name in ("speaker", "utt", "channel", "contaminated"):
            if len(getattr(self, name)) != n:
                raise ValueError(f"{name} has {len(getattr(self, name))} rows, emb has {n}")
        idx: dict[str, dict[str, dict[tuple[str, bool], int]]] = {}
        for i in range(n):
            key = (str(self.channel[i]), bool(self.contaminated[i]))
            slot = idx.setdefault(str(self.speaker[i]), {}).setdefault(str(self.utt[i]), {})
            if key in slot:
                raise ValueError(f"duplicate variant {key} for {self.utt[i]}")
            slot[key] = i
        self._index = idx
        # catalogues computed once: draws must not scan the whole bank
        self._channels = tuple(sorted({str(c) for c in np.unique(np.asarray(self.channel).astype(str))}))
        self._speakers = tuple(sorted(idx))
        self._utts = {spk: tuple(sorted(u)) for spk, u in idx.items()}

    @property
    def dim(self) -> int:
        return int(self.emb.shape[1])

    def speakers(self) -> list[str]:
        return list(self._speakers)

    def channels(self) -> list[str]:
        return list(self._channels)

    def save(self, path: Path) -> None:
        np.savez(path, emb=self.emb, speaker=self.speaker.astype(str), utt=self.utt.astype(str),
                 channel=self.channel.astype(str), contaminated=self.contaminated.astype(bool),
                 embedder=np.array(self.embedder), embedder_sha256=np.array(self.embedder_sha256))

    @classmethod
    def load(cls, path: Path) -> "EnrollmentBank":
        z = np.load(path, allow_pickle=False)
        return cls(emb=z["emb"], speaker=z["speaker"], utt=z["utt"], channel=z["channel"],
                   contaminated=z["contaminated"], embedder=str(z["embedder"]),
                   embedder_sha256=str(z["embedder_sha256"]))

    def check(self, partitions: Mapping[str, SpeakerPartition], channels: Sequence[str],
              contaminated: Sequence[bool] = (False, True)) -> None:
        """Every entry lies in its speaker's enrollment pool, and every bank
        utterance has every requested (channel, contaminated) variant."""
        for spk, utts in self._index.items():
            part = partitions.get(spk)
            if part is None:
                raise ValueError(f"bank speaker {spk} has no partition")
            for u, variants in utts.items():
                if u not in part.enroll:
                    raise ValueError(f"bank utterance {u} is not in {spk}'s enrollment pool")
                for ch in channels:
                    for c in contaminated:
                        if (ch, bool(c)) not in variants:
                            raise ValueError(f"bank utterance {u} lacks variant ({ch}, contaminated={c})")

    def candidates(self, partition: SpeakerPartition) -> list[str]:
        """Bank utterances of the partition's speaker; each must be in its enrollment pool."""
        utts = list(self._utts.get(partition.speaker, ()))
        bad = [u for u in utts if u not in partition.enroll]
        if bad:
            raise ValueError(f"bank utterances outside the enrollment pool: {bad[:3]}")
        return utts

    def row(self, speaker: str, utt: str, channel: str, contaminated: bool) -> int:
        try:
            return self._index[speaker][utt][(channel, bool(contaminated))]
        except KeyError:
            raise ValueError(f"bank lacks variant ({channel}, contaminated={contaminated}) of {utt}") from None


@dataclass(frozen=True)
class EnrollPolicy:
    """How training draws an enrollment profile (DESIGN.md section 5).

    Per profile: k and the contamination rate r. Per dictation, independently:
    contaminated with probability r; on the mixture's channel with probability
    p_match_channel, else on another channel drawn uniformly from the bank's."""

    k_choices: tuple[int, ...] = (1, 2, 3, 5, 10, 20, 30)
    contamination_rates: tuple[float, ...] = (0.0, 0.2, 0.4)
    contamination_probs: tuple[float, ...] = (0.5, 0.3, 0.2)
    p_match_channel: float = 0.5

    @classmethod
    def clean30(cls) -> "EnrollPolicy":
        """The A5 ablation: always 30 clean dictations on the mixture's channel."""
        return cls(k_choices=(30,), contamination_rates=(0.0,), contamination_probs=(1.0,), p_match_channel=1.0)


@dataclass(frozen=True)
class EnrollDraw:
    profile: np.ndarray
    k: int
    contamination_rate: float
    contaminated: int
    matched: int  # dictations on the mixture's channel
    utts: tuple[str, ...]
    level: str


TARGET_LEVELS = ("cross_project", "same_project_cross_chapter")


def target_eligible(partition: SpeakerPartition) -> bool:
    """Training targets must have their enrollment from a different chapter at
    least; `same_chapter` speakers (one chapter only) serve as interferers only,
    which removes the same-recording shortcut at its source."""
    return partition.level in TARGET_LEVELS


def check_mixture_targets(partition: SpeakerPartition, target_utts: Sequence[str]) -> None:
    if not target_eligible(partition):
        raise ValueError(f"speaker {partition.speaker} ({partition.level}) cannot be a training target")
    bad = [u for u in target_utts if u not in partition.mixture]
    if bad:
        raise ValueError(f"mixture target utterances outside {partition.speaker}'s mixture pool: {bad[:3]}")


def draw_profile(bank: EnrollmentBank, partition: SpeakerPartition, mixture_channel: str,
                 policy: EnrollPolicy, rng: np.random.Generator) -> EnrollDraw:
    """Raises rather than substituting a variant the policy did not ask for."""
    cands = bank.candidates(partition)
    if not cands:
        raise ValueError(f"no enrollment utterances for speaker {partition.speaker}")
    k = int(min(rng.choice(policy.k_choices), len(cands)))
    r = float(rng.choice(policy.contamination_rates, p=policy.contamination_probs))
    others = [c for c in bank.channels() if c != mixture_channel]
    chosen = sorted(rng.choice(len(cands), size=k, replace=False).tolist())
    rows, n_cont, n_match = [], 0, 0
    for j in chosen:
        cont = bool(rng.random() < r)
        match = bool(rng.random() < policy.p_match_channel)
        if match:
            ch = mixture_channel
        else:
            if not others:
                raise ValueError(f"no channel other than {mixture_channel} in the bank")
            ch = others[int(rng.integers(len(others)))]
        rows.append(bank.row(partition.speaker, cands[j], ch, cont))
        n_cont += int(cont)
        n_match += int(match)
    prof = mean_profile(np.asarray(bank.emb[rows], dtype=np.float32))
    return EnrollDraw(prof, k, r, n_cont, n_match, tuple(cands[j] for j in chosen), partition.level)


def draw_impostor(bank: EnrollmentBank, partitions: Mapping[str, SpeakerPartition], absent: Sequence[str],
                  policy: EnrollPolicy, rng: np.random.Generator, mixture_channel: str) -> tuple[str, EnrollDraw]:
    """A profile of a bank speaker not in `absent` (the mixture's speakers)."""
    excl = set(absent)
    pool = [s for s in bank.speakers() if s not in excl and target_eligible(partitions[s])]
    if not pool:
        raise ValueError("no impostor speaker available")
    spk = pool[int(rng.integers(len(pool)))]
    return spk, draw_profile(bank, partitions[spk], mixture_channel, policy, rng)


def librispeech_partitions(split: str) -> dict[str, SpeakerPartition]:
    """Partitions of every speaker of a split. Refuses the sealed test split."""
    if split == "test":
        raise ValueError("the test split is sealed")
    from lfspk import paths, splits

    chapter_project = parse_chapters_txt((paths.LIBRISPEECH / "CHAPTERS.TXT").read_text(encoding="utf-8",
                                                                                          errors="replace"))
    utts = {s.id: [p.stem for p in splits.utterances(s)] for s in splits.speakers(split)}
    return build_partitions(utts, chapter_project)
