"""Packed int16 audio cache for stage 3 (an I/O optimisation only).

The data disk is a shared USB hard disk; stage-3 training reads two random
LibriSpeech utterances per mixture (about 400k reads per run). The cache
decodes each needed utterance once into one int16 file that is read
sequentially afterwards. LibriSpeech is 16-bit PCM and soundfile's float32 read
of 16-bit audio is exactly int16 / 32768, so `load` returns bit-identical
arrays (tested); `build` refuses any file that is not 16 kHz mono PCM_16.

Layout (immutable, content-addressed generations, as W4's embedding cache):

    runs/W2/audiocache/<name>/CURRENT       id of the current generation
    runs/W2/audiocache/<name>/gen-<id>/
        audio.int16   little-endian int16, utterances concatenated in id order
        index.json    {utt: [offset, samples]}, offsets contiguous from 0
        meta.json     audio_sha256, index_sha256, ids_sha256, utterances,
                      samples, source, created
    <id> = first 16 hex of SHA-256("<audio_sha256>\\n<index_sha256>\\n")

Builders write into a private temporary directory and publish it with one
directory rename, then replace CURRENT atomically; concurrent builders of the
same content produce the same id and keep the first. Readers resolve CURRENT
once and pin that generation; they check the index hash, the generation id,
every index entry's bounds and contiguous coverage, and (in `verify`, which
reads every byte) the audio hash, before any `load`.

    ./python -m lfspk.probe.audiocache --name train-halfB --split train
    ./python -m lfspk.probe.audiocache --name dev --split dev
"""

from __future__ import annotations

import argparse
import hashlib
import json
import shutil
import tempfile
import time
import uuid
from pathlib import Path
from typing import Iterable, Mapping, Sequence

import numpy as np

from lfspk import paths

ROOT = paths.RUNS / "W2" / "audiocache"
CURRENT = "CURRENT"


def ids_sha256(utts: Iterable[str]) -> str:
    return hashlib.sha256("".join(u + "\n" for u in sorted(set(utts))).encode()).hexdigest()


def generation_id(audio_sha: str, index_sha: str) -> str:
    return hashlib.sha256(f"{audio_sha}\n{index_sha}\n".encode()).hexdigest()[:16]


def build(utts: Sequence[str], where: Mapping[str, str], directory: Path, source: str = "") -> str:
    """Decode `utts` into a new generation under `directory`, publish it and
    point CURRENT at it. Returns the generation id."""
    import soundfile as sf

    utts = sorted(set(utts))
    if not utts:
        raise ValueError("no utterances")
    directory.mkdir(parents=True, exist_ok=True)
    tmp = Path(tempfile.mkdtemp(prefix=".gen.tmp-", dir=directory))
    try:
        index, offset = {}, 0
        h = hashlib.sha256()
        with open(tmp / "audio.int16", "wb") as fh:
            for u in utts:
                info = sf.info(where[u])
                if info.samplerate != 16000 or info.channels != 1 or info.subtype != "PCM_16":
                    raise ValueError(f"{u}: expected 16 kHz mono PCM_16, got {info.samplerate} Hz, "
                                     f"{info.channels} ch, {info.subtype}")
                a, _ = sf.read(where[u], dtype="int16")
                if a.size == 0:
                    raise ValueError(f"{u}: empty")
                b = a.astype("<i2").tobytes()
                fh.write(b)
                h.update(b)
                index[u] = [offset, int(a.size)]
                offset += int(a.size)
        index_bytes = json.dumps(index, sort_keys=True).encode()
        (tmp / "index.json").write_bytes(index_bytes)
        audio_sha, index_sha = h.hexdigest(), hashlib.sha256(index_bytes).hexdigest()
        gen = generation_id(audio_sha, index_sha)
        meta = {"audio_sha256": audio_sha, "index_sha256": index_sha, "ids_sha256": ids_sha256(utts),
                "utterances": len(index), "samples": offset, "source": source,
                "created": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())}
        (tmp / "meta.json").write_text(json.dumps(meta, indent=1))
        final = directory / f"gen-{gen}"
        try:
            tmp.rename(final)
        except OSError:
            if not final.is_dir():
                raise
            shutil.rmtree(tmp)  # same content already published by another builder: keep it
    except BaseException:
        shutil.rmtree(tmp, ignore_errors=True)
        raise
    ptr = directory / f".{CURRENT}.tmp-{uuid.uuid4().hex[:8]}"
    ptr.write_text(gen + "\n")
    ptr.replace(directory / CURRENT)
    return gen


def check_index(index: Mapping[str, Sequence[int]], samples: int) -> None:
    """Every entry in bounds with a positive length; entries tile [0, samples)
    exactly (sorted by offset: contiguous, no overlap, no gap)."""
    spans = []
    for u, v in index.items():
        if len(v) != 2:
            raise ValueError(f"{u}: bad index entry")
        o, n = int(v[0]), int(v[1])
        if o < 0 or n <= 0 or o + n > samples:
            raise ValueError(f"{u}: entry [{o}, {n}] out of bounds for {samples} samples")
        spans.append((o, n))
    spans.sort()
    pos = 0
    for o, n in spans:
        if o != pos:
            raise ValueError(f"index does not tile the audio (gap or overlap at {pos})")
        pos = o + n
    if pos != samples:
        raise ValueError("index does not cover the audio")


class AudioCache:
    """Reader pinned to one generation. Construction checks the index (hash,
    generation id, bounds, coverage, utterance set); `verify()` reads every
    audio byte, checks its hash and leaves the file in the page cache; `load`
    refuses until then. Pickling (DataLoader workers) carries the pinned,
    verified state; each process opens its own memmap."""

    def __init__(self, directory: Path, generation: str | None = None):
        directory = Path(directory)
        gen = generation or (directory / CURRENT).read_text().strip()
        self.directory, self.generation = directory, gen
        self.dir = directory / f"gen-{gen}"
        self.meta = json.loads((self.dir / "meta.json").read_text())
        index_bytes = (self.dir / "index.json").read_bytes()
        if hashlib.sha256(index_bytes).hexdigest() != self.meta["index_sha256"]:
            raise ValueError(f"{self.dir}: index.json does not match its recorded hash")
        if generation_id(self.meta["audio_sha256"], self.meta["index_sha256"]) != gen:
            raise ValueError(f"{self.dir}: metadata does not match the generation id")
        index = json.loads(index_bytes)
        self.samples = int(self.meta["samples"])
        check_index(index, self.samples)
        if ids_sha256(index) != self.meta["ids_sha256"] or len(index) != self.meta["utterances"]:
            raise ValueError(f"{self.dir}: utterance set does not match the metadata")
        if (self.dir / "audio.int16").stat().st_size != 2 * self.samples:
            raise ValueError(f"{self.dir}: audio size mismatch")
        self.index = {u: (int(o), int(n)) for u, (o, n) in index.items()}
        self.verified = False
        self._data = None

    def __getstate__(self):
        d = dict(self.__dict__)
        d["_data"] = None
        return d

    def verify(self, chunk: int = 1 << 26) -> None:
        h = hashlib.sha256()
        with open(self.dir / "audio.int16", "rb") as fh:
            while block := fh.read(chunk):
                h.update(block)
        if h.hexdigest() != self.meta["audio_sha256"]:
            raise ValueError(f"{self.dir}: audio does not match its recorded SHA-256")
        self.verified = True

    @property
    def ids(self) -> set[str]:
        return set(self.index)

    def __contains__(self, utt: str) -> bool:
        return utt in self.index

    def load(self, utt: str) -> np.ndarray:
        if not self.verified:
            raise RuntimeError("verify() the cache before loading from it")
        if self._data is None:
            self._data = np.memmap(self.dir / "audio.int16", dtype="<i2", mode="r")
        off, n = self.index[utt]
        return np.asarray(self._data[off:off + n], dtype=np.float32) / np.float32(32768.0)


def require_ids(cache: AudioCache, expected: Iterable[str], what: str) -> None:
    """The cache must hold exactly the utterances the run will use."""
    expected = set(expected)
    if cache.ids != expected:
        missing, extra = expected - cache.ids, cache.ids - expected
        raise ValueError(f"{what}: cache {cache.dir} differs from the expected utterance set "
                         f"({len(missing)} missing, {len(extra)} extra)")


def train_half_b_utts(selection: Mapping[str, Sequence[str]]) -> list[str]:
    from .frames import halves

    _, half_b = halves(list(selection))
    return [u for s in half_b for u in selection[s]]


def dev_utts(plans: Sequence[Mapping]) -> list[str]:
    out = []
    for p in plans:
        out += list(p["test"]) + [u for m in p["enroll_models"] for u in m]
    return out


def main(argv=None) -> None:
    """Build the cache for exactly the utterances of a stage-2 feature set's
    manifest (the one stage 3 trains from): train half B, or dev test + enrollment."""
    from .extract import utterance_map
    from .verify import load_feats

    ap = argparse.ArgumentParser()
    ap.add_argument("--name", required=True)
    ap.add_argument("--split", choices=["train", "dev"], required=True)
    ap.add_argument("--feature", default="base", help="stage-2 feature set whose manifest defines the utterances")
    args = ap.parse_args(argv)
    paths.require_mount()
    sel = load_feats(args.feature, args.split)[2]
    if args.split == "train":
        utts = train_half_b_utts(sel["selection"])
        source = f"feats/{args.feature}/train selection.json, stage-3 half B (frames.halves)"
    else:
        utts = dev_utts(sel["plans"])
        source = f"feats/{args.feature}/dev selection.json plans: test + enrollment"
    where = utterance_map(args.split)[1]
    gen = build(utts, where, ROOT / args.name, source)
    meta = AudioCache(ROOT / args.name, gen).meta
    print(args.name, gen, meta["utterances"], "utterances", round(meta["samples"] / 16000 / 3600, 2), "h",
          meta["audio_sha256"])


if __name__ == "__main__":
    main()
