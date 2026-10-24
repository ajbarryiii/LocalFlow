"""Shared clean-speech embedding cache (format recorded in CONTRACT.md NOTES).

Layout, one directory per embedder and split, holding immutable generations:

    runs/W4/emb/<embedder>/<split>/CURRENT          id of the current generation
    runs/W4/emb/<embedder>/<split>/gen-<id>/
        meta.json   embedder name, weights_sha256, dim, split, crop policy,
                    selection policy, git commit, command, created (UTC)
        index.tsv   row, utt_id, speaker, chapter, sex, crop_start, crop_len,
                    num_samples   (crop_start = crop_len = -1: full utterance)
        emb.npy     float32 [rows, dim], L2-normalised, row i = index row i

dev: every dev-clean utterance, full, plus one 2 s crop per utterance at a
seeded offset (`roles.crop_offset`, seed in meta). Utterances of 2 s or less
give a crop equal to the full utterance (crop_len = num_samples).
train: up to 40 utterances per train-clean-360 speaker (`roles.select_train_utts`),
full only.

Extraction runs through W1's `lfspk.embed.embedder.load_embedder` (W4 writes
no embedder loaders).
"""

from __future__ import annotations

import csv
import hashlib
import io
import json
import shutil
import tempfile
import uuid
from dataclasses import dataclass
from pathlib import Path

import numpy as np

from .. import paths

CACHE_ROOT = paths.RUNS / "W4" / "emb"
CROP_SECONDS = 2.0
CROP_SEED = 20261021
SELECT_SEED = 20261021
TRAIN_LIMIT = 40
COLUMNS = ("row", "utt_id", "speaker", "chapter", "sex", "crop_start", "crop_len", "num_samples")


@dataclass(frozen=True)
class Row:
    utt_id: str
    speaker: str
    chapter: str
    sex: str
    crop_start: int
    crop_len: int
    num_samples: int

    @property
    def is_full(self) -> bool:
        return self.crop_start == -1


@dataclass
class Cache:
    meta: dict
    rows: list[Row]
    emb: np.ndarray

    def select(self, full: bool) -> tuple[list[Row], np.ndarray]:
        idx = [i for i, r in enumerate(self.rows) if r.is_full == full]
        return [self.rows[i] for i in idx], self.emb[idx]


def cache_dir(embedder: str, split: str, root: Path = CACHE_ROOT) -> Path:
    return root / embedder / split


def _sha256(path: Path) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for block in iter(lambda: f.read(1 << 20), b""):
            h.update(block)
    return h.hexdigest()


CURRENT = "CURRENT"


def write(directory: Path, meta: dict, rows: list[Row], emb: np.ndarray, require_unit: bool = True) -> str:
    """Publish one immutable generation; return its id.

    Files go into `directory/gen-<id>/` (written in a temporary sibling, then
    renamed; an existing generation with the same id has identical content and
    is kept). `directory/CURRENT` holding the id is then replaced atomically.
    Generations are never modified or deleted by code (reclaim by hand), so a
    reader that pinned a generation always sees consistent bytes."""
    if emb.dtype != np.float32 or emb.ndim != 2 or emb.shape[0] != len(rows):
        raise ValueError("emb must be float32 [rows, dim]")
    if not np.isfinite(emb).all():
        raise ValueError("embeddings must be finite")
    if require_unit and not np.allclose(np.linalg.norm(emb, axis=1), 1.0, atol=1e-3):
        raise ValueError("embeddings must be L2-normalised")
    directory = Path(directory)
    directory.mkdir(parents=True, exist_ok=True)
    buf = io.BytesIO()
    np.save(buf, emb)
    emb_bytes = buf.getvalue()
    idx = io.StringIO()
    w = csv.writer(idx, delimiter="\t", lineterminator="\n")
    w.writerow(COLUMNS)
    for i, r in enumerate(rows):
        w.writerow((i, r.utt_id, r.speaker, r.chapter, r.sex, r.crop_start, r.crop_len, r.num_samples))
    idx_bytes = idx.getvalue().encode("utf-8")
    meta = dict(meta, dim=int(emb.shape[1]), n_rows=len(rows),
                index_sha256=hashlib.sha256(idx_bytes).hexdigest(), emb_sha256=hashlib.sha256(emb_bytes).hexdigest())
    gen = hashlib.sha256((meta["index_sha256"] + meta["emb_sha256"]).encode()).hexdigest()[:16]
    meta["generation"] = gen
    final = directory / f"gen-{gen}"
    if not final.exists():
        tmp = Path(tempfile.mkdtemp(prefix=f".gen-{gen}.tmp-", dir=directory))
        try:
            (tmp / "emb.npy").write_bytes(emb_bytes)
            (tmp / "index.tsv").write_bytes(idx_bytes)
            (tmp / "meta.json").write_text(json.dumps(meta, indent=2, sort_keys=True) + "\n", encoding="utf-8")
            tmp.rename(final)
        except BaseException:
            shutil.rmtree(tmp, ignore_errors=True)
            raise
    ptr = directory / f".{CURRENT}.tmp-{uuid.uuid4().hex[:8]}"
    ptr.write_text(gen + "\n", encoding="utf-8")
    ptr.replace(directory / CURRENT)
    return gen


def current_generation(directory: Path) -> str:
    return (Path(directory) / CURRENT).read_text(encoding="utf-8").strip()


def read(directory: Path, generation: str | None = None) -> Cache:
    """Read one generation (default: CURRENT, resolved once). Every file is read
    into memory once, its hash checked against meta.json, and parsed from those
    same bytes."""
    directory = Path(directory)
    gen = generation or current_generation(directory)
    gdir = directory / f"gen-{gen}"
    meta = json.loads((gdir / "meta.json").read_bytes().decode("utf-8"))
    if meta.get("generation") != gen:
        raise ValueError(f"{gdir}: meta.json names generation {meta.get('generation')}")
    idx_bytes = (gdir / "index.tsv").read_bytes()
    emb_bytes = (gdir / "emb.npy").read_bytes()
    if hashlib.sha256(idx_bytes).hexdigest() != meta.get("index_sha256"):
        raise ValueError(f"{gdir}/index.tsv: hash does not match meta.json")
    if hashlib.sha256(emb_bytes).hexdigest() != meta.get("emb_sha256"):
        raise ValueError(f"{gdir}/emb.npy: hash does not match meta.json")
    rows: list[Row] = []
    r = csv.reader(io.StringIO(idx_bytes.decode("utf-8")), delimiter="\t")
    header = next(r)
    if tuple(header) != COLUMNS:
        raise ValueError(f"unexpected header {header}")
    for i, rec in enumerate(r):
        if int(rec[0]) != i:
            raise ValueError("rows out of order")
        rows.append(Row(rec[1], rec[2], rec[3], rec[4], int(rec[5]), int(rec[6]), int(rec[7])))
    emb = np.load(io.BytesIO(emb_bytes), allow_pickle=False)
    if emb.shape != (len(rows), meta["dim"]):
        raise ValueError("emb.npy does not match index.tsv / meta.json")
    return Cache(meta, rows, emb)


def is_inside_or_contains(path: Path, root: Path) -> bool:
    """True if path is root, inside it, or contains it (smoke-output guard)."""
    p, r = Path(path).resolve(), Path(root).resolve()
    return p == r or r in p.parents or p in r.parents


def validate(cache: Cache, embedder: str, split: str, expected_ids: set[tuple[str, bool]]) -> None:
    """Refuse a cache that is partial, for another embedder or split, or that
    does not cover exactly the planned utterances (full and crop rows)."""
    m = cache.meta
    if m.get("embedder") != embedder or m.get("split") != split:
        raise ValueError(f"cache is for {m.get('embedder')}/{m.get('split')}, wanted {embedder}/{split}")
    if m.get("limit_speakers"):
        raise ValueError("partial (smoke) cache")
    have = {(r.utt_id, r.is_full) for r in cache.rows}
    if len(have) != len(cache.rows):
        raise ValueError("duplicate rows")
    if have != expected_ids:
        raise ValueError(f"cache coverage differs from plan: {len(have ^ expected_ids)} rows")
