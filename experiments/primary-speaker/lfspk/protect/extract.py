"""Build the shared clean-speech embedding cache (embcache.py documents the format).

    ./python -m lfspk.protect.extract --embedder ecapa-vox --split dev
    ./python-nemo -m lfspk.protect.extract --embedder titanet-s --split train

GPU via W1's embedder interface; run as a gpu:shared job.
"""

from __future__ import annotations

import argparse
import datetime as dt
import os
import subprocess
import sys
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

import numpy as np
import soundfile as sf

from .. import paths, splits
from . import embcache, roles


# Target splits get every utterance, full and as a 2 s crop (dev-like policy);
# clone_eval (train-clean-100) holds extra W4 cloning-risk targets only.
TARGET_SPLITS = ("dev", "clone_eval")
CACHED_SPLITS = ("train",) + TARGET_SPLITS


def planned_utts(split: str, root: Path = paths.LIBRISPEECH):
    """(speaker, {utt id: flac path}) for the utterances a split's cache holds,
    speakers in id order; no audio is opened."""
    if split not in CACHED_SPLITS:
        raise ValueError("W4 caches train, dev and clone_eval only (test is sealed)")
    for spk in splits.speakers(split, root):
        files = {p.stem: p for p in splits.utterances(spk, root)}
        ids = sorted(files, key=roles.utt_key)
        if split == "train":
            ids = roles.select_train_utts(ids, spk.id, embcache.SELECT_SEED, embcache.TRAIN_LIMIT)
        yield spk, {i: files[i] for i in ids}


def planned_ids(split: str, root: Path = paths.LIBRISPEECH) -> set[tuple[str, bool]]:
    """(utt id, is_full) of every row a complete cache for `split` holds."""
    out = set()
    for _, files in planned_utts(split, root):
        for uid in files:
            out.add((uid, True))
            if split in TARGET_SPLITS:
                out.add((uid, False))
    return out


def plan_rows(split: str, root: Path = paths.LIBRISPEECH) -> list[tuple[embcache.Row, Path]]:
    """Every (row, flac path) the cache holds for a split, in a fixed order."""
    crop = int(embcache.CROP_SECONDS * 16_000)
    out: list[tuple[embcache.Row, Path]] = []
    for spk, files in planned_utts(split, root):
        for uid in files:
            n = sf.info(str(files[uid])).frames
            ch = uid.split("-")[1]
            out.append((embcache.Row(uid, spk.id, ch, spk.sex, -1, -1, n), files[uid]))
            if split in TARGET_SPLITS:
                start = roles.crop_offset(uid, n, crop, embcache.CROP_SEED)
                out.append((embcache.Row(uid, spk.id, ch, spk.sex, start, min(crop, n), n), files[uid]))
    return out


def load_segment(row: embcache.Row, path: Path) -> np.ndarray:
    audio, sr = sf.read(str(path), dtype="float32", always_2d=False)
    if sr != 16_000 or audio.ndim != 1 or audio.size != row.num_samples:
        raise ValueError(f"{path}: unexpected format")
    if not row.is_full:
        audio = audio[row.crop_start : row.crop_start + row.crop_len]
    return np.ascontiguousarray(audio)


def git_commit() -> str:
    try:
        return subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=Path(__file__).resolve().parents[2],
                                       text=True).strip()
    except Exception:
        return "unknown"


def last_commit(path: str) -> str:
    try:
        return subprocess.check_output(["git", "log", "-1", "--format=%H", "--", path],
                                       cwd=Path(__file__).resolve().parents[2], text=True).strip()
    except Exception:
        return "unknown"


def embedder_source_clean() -> bool:
    """True if W1's embedder module has no uncommitted changes (the cache
    records the repo commit, so the code that produced it must be committed)."""
    repo = Path(__file__).resolve().parents[2]
    r = subprocess.run(["git", "diff", "--quiet", "HEAD", "--", "lfspk/embed/"], cwd=repo)
    return r.returncode == 0


def main(argv: list[str] | None = None) -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--embedder", required=True)
    ap.add_argument("--split", required=True, choices=CACHED_SPLITS)
    ap.add_argument("--limit-speakers", type=int, default=0, help="smoke runs only")
    ap.add_argument("--out", type=Path, default=None)
    ap.add_argument("--device", default=None)
    ap.add_argument("--allow-dirty", action="store_true", help="smoke runs only")
    args = ap.parse_args(argv)
    paths.require_mount()
    if not embedder_source_clean() and not args.allow_dirty:
        raise SystemExit("lfspk/embed has uncommitted changes; the cache must come from committed code")

    import torch
    from ..embed.embedder import load_embedder  # W1's interface

    if torch.cuda.is_available() and "AGENT_JOBS_VRAM_FRACTION" in os.environ:
        torch.cuda.set_per_process_memory_fraction(float(os.environ["AGENT_JOBS_VRAM_FRACTION"]))
    device = args.device or ("cuda" if torch.cuda.is_available() else "cpu")
    emb_model = load_embedder(args.embedder, device)

    plan = plan_rows(args.split)
    if args.limit_speakers:
        if args.out is None or embcache.is_inside_or_contains(args.out, embcache.CACHE_ROOT):
            raise SystemExit("--limit-speakers needs --out outside the shared cache root")
        keep = sorted({r.speaker for r, _ in plan}, key=int)[: args.limit_speakers]
        plan = [(r, p) for r, p in plan if r.speaker in keep]
    out_dir = args.out or embcache.cache_dir(args.embedder, args.split)

    vecs = np.zeros((len(plan), emb_model.dim), dtype=np.float32)
    chunk, lookahead = 64, 2  # at most (1 + lookahead) chunks of decoded audio in memory
    starts = list(range(0, len(plan), chunk))
    with ThreadPoolExecutor(max_workers=6) as pool:
        submit = lambda st: [pool.submit(load_segment, *rp) for rp in plan[st : st + chunk]]
        pending = {st: submit(st) for st in starts[:lookahead]}
        for j, st in enumerate(starts):
            if j + lookahead < len(starts):
                pending[starts[j + lookahead]] = submit(starts[j + lookahead])
            batch = [f.result() for f in pending.pop(st)]
            vecs[st : st + len(batch)] = emb_model.embed_batch(batch)
            del batch
            if st % 2048 == 0:
                print(f"{st}/{len(plan)}", flush=True)
    meta = {
        "embedder": emb_model.name,
        "weights_sha256": emb_model.weights_sha256,
        "dim": int(emb_model.dim),
        "split": args.split,
        "subsets": list(splits.SPLIT_SUBSETS.get(args.split) or splits.AUX_SUBSETS[args.split]),
        "crop_seconds": embcache.CROP_SECONDS if args.split in TARGET_SPLITS else None,
        "crop_seed": embcache.CROP_SEED if args.split in TARGET_SPLITS else None,
        "train_limit": embcache.TRAIN_LIMIT if args.split == "train" else None,
        "select_seed": embcache.SELECT_SEED if args.split == "train" else None,
        "limit_speakers": args.limit_speakers,
        "librispeech_root": str(paths.LIBRISPEECH),
        "git_commit": git_commit(),
        "embedder_source_clean": embedder_source_clean(),
        "embedder_module_commit": last_commit("lfspk/embed/embedder.py"),
        "command": " ".join(sys.argv),
        "created": dt.datetime.now(dt.timezone.utc).isoformat(timespec="seconds"),
    }
    gen = embcache.write(out_dir, meta, [r for r, _ in plan], vecs)
    print(f"wrote {len(plan)} rows to {out_dir}, generation {gen}")


if __name__ == "__main__":
    main()
