"""Load cached embeddings and the fixed dev roles for W4 experiments."""

from __future__ import annotations

from dataclasses import dataclass, field

import numpy as np

from .. import paths
from . import embcache, roles
from .transforms import l2n

ROLE_SEED = 4041


@dataclass
class TrainSet:
    X: np.ndarray  # [N, D] full-utterance embeddings
    y: np.ndarray  # speaker id strings
    sex: dict[str, str]
    meta: dict
    utt_ids: list[str] = field(default_factory=list)  # aligned with X rows

    def speaker_centroids(self) -> tuple[np.ndarray, np.ndarray]:
        spk = np.unique(self.y)
        return spk, np.stack([l2n(self.X[self.y == s].mean(0)) for s in spk])


@dataclass
class DevSet:
    speakers: list[str]  # sorted by int id
    sex: dict[str, str]
    roles: dict[str, roles.DevRoles]
    full: dict[str, np.ndarray]  # utt id -> embedding
    crop: dict[str, np.ndarray]  # utt id -> 2 s crop embedding
    meta: dict

    def stack(self, ids, which: str = "full") -> np.ndarray:
        table = self.full if which == "full" else self.crop
        return np.stack([table[i] for i in ids])

    def profile_utts(self, k: int) -> list[np.ndarray]:
        """Enrollment embeddings E[:k] per speaker, in speaker order."""
        return [self.stack(self.roles[s].E[:k]) for s in self.speakers]

    def raw_profiles(self, k: int) -> np.ndarray:
        return np.stack([l2n(e.mean(0)) for e in self.profile_utts(k)])

    def r_centroids(self) -> np.ndarray:
        return np.stack([l2n(self.stack(self.roles[s].R).mean(0)) for s in self.speakers])


def _load(embedder: str, split: str, validate: bool, generation: str | None = None) -> embcache.Cache:
    c = embcache.read(embcache.cache_dir(embedder, split), generation)
    if validate:
        from .extract import planned_ids

        embcache.validate(c, embedder, split, planned_ids(split))
    return c


def load_train(embedder: str, validate: bool = True, generation: str | None = None) -> TrainSet:
    c = _load(embedder, "train", validate, generation)
    rows, X = c.select(full=True)
    return TrainSet(X.astype(np.float64), np.array([r.speaker for r in rows]),
                    {r.speaker: r.sex for r in rows}, c.meta, [r.utt_id for r in rows])


def chapter_projects() -> dict[str, str]:
    return roles.parse_chapters_txt((paths.LIBRISPEECH / "CHAPTERS.TXT").read_text(encoding="utf-8", errors="replace"))


def dev_roles_from_rows(rows: list[embcache.Row], projects: dict[str, str] | None = None) -> dict[str, roles.DevRoles]:
    projects = chapter_projects() if projects is None else projects
    by_spk: dict[str, list[roles.Utt]] = {}
    for r in rows:
        if r.is_full:
            by_spk.setdefault(r.speaker, []).append(
                roles.Utt(r.utt_id, r.speaker, r.chapter, r.num_samples, projects[r.chapter]))
    return {s: roles.assign_dev_roles(u, ROLE_SEED) for s, u in by_spk.items()}


def load_dev(embedder: str, validate: bool = True, generation: str | None = None,
             split: str = "dev") -> DevSet:
    """A target split (dev, or the auxiliary clone_eval) with the fixed roles."""
    if split not in ("dev", "clone_eval"):
        raise ValueError(f"not a target split: {split}")
    c = _load(embedder, split, validate, generation)
    full = {r.utt_id: e.astype(np.float64) for r, e in zip(c.rows, c.emb) if r.is_full}
    crop = {r.utt_id: e.astype(np.float64) for r, e in zip(c.rows, c.emb) if not r.is_full}
    role_map = dev_roles_from_rows(c.rows)
    speakers = sorted(role_map, key=int)
    return DevSet(speakers, {r.speaker: r.sex for r in c.rows}, role_map, full, crop, c.meta)
