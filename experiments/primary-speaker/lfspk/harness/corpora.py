"""Corpus indexes with train/dev/test splits for every auxiliary corpus.

`build_index` writes JSON indexes under INDEX_DIR once (a supervised job);
`Corpus(split)` loads them lazily. Split rules are documented in DESIGN.md
section 2 and recorded in CONTRACT.md NOTES. Nothing here decodes much audio
except the OpenSLR 26 distance estimate (direct-path delay) at index time.
"""

from __future__ import annotations

import json
import re
from concurrent.futures import ProcessPoolExecutor
from dataclasses import dataclass
from functools import cached_property, lru_cache
from pathlib import Path
from typing import Any

import numpy as np

from .. import paths, splits
from .rirs import BANK_SIZES, distance_from_delay, normalise_rir, simulate_room
from .util import audio_info, load_audio, sha256_file, split_by_hash, stable_int

INDEX_VERSION = "v1"
INDEX_DIR = paths.DATA / "harness" / "index" / INDEX_VERSION
BANK_DIR = paths.DATA / "harness" / "rirbank"

MUSAN_NM = paths.DATA / "musan-noise-music" / "musan"
MUSAN_USGOV = Path("/mnt/hd/wilderness-labs-stt/noisy-dev/extracted/musan/musan-7d5ce2e862a3fce5/musan/speech/us-gov")
DEMAND_ROOT = Path("/mnt/hd/wilderness-labs-stt/noisy-dev/extracted/demand")
BUT_ROOT = Path("/mnt/hd/wilderness-labs-stt/noisy-dev/extracted/but-reverbdb/rir-only-9183a3c8f4e8a248")
SLR26_ROOT = paths.DATA / "openslr26" / "simulated_rirs_16k"
SLR28_REAL = paths.DATA / "openslr28" / "RIRS_NOISES" / "real_rirs_isotropic_noises"

# Indoor DEMAND environments without intelligible background speech (to be
# confirmed by the ASR check in DESIGN.md section 7; failures are dropped for
# every split alike). Whole environments are assigned to splits, so test
# ambience comes from rooms (and recording setups) never heard in training.
DEMAND_ENVS = ("OOFFICE", "OMEETING", "OHALLWAY", "DLIVING", "DKITCHEN", "DWASHING")


def demand_env_split(env: str) -> str:
    """Rank environments by a stable hash: first -> test, second -> dev, rest -> train."""
    ranked = sorted(DEMAND_ENVS, key=lambda e: stable_int("demand-env", e))
    return "test" if env == ranked[0] else "dev" if env == ranked[1] else "train"


# Real-RIR rooms. Explicit assignment because there are few rooms; offices and
# meeting rooms are spread over the splits. Everything not listed is train.
REAL_ROOM_SPLIT = {
    "air_office": "dev", "RVB2014_mediumroom2": "dev", "RWCP_cirline_ofc": "dev", "BUT_VUT_FIT_L212": "dev",
    "air_meeting": "test", "RVB2014_smallroom2": "test", "RWCP_circle_e1b": "test", "BUT_VUT_FIT_L207": "test",
}


def real_room_key(rir_list_room: str, filename: str) -> str | None:
    """Group SLR28 real-RIR files into physical rooms; None excludes the file
    (anechoic, AIR mock-up phone positions, unidentified RWCP setups)."""
    if "_ane" in rir_list_room or rir_list_room.startswith("air_phone") or "type3" in filename:
        return None
    m = re.match(r"air_binaural_([a-z_]+?)_\d", rir_list_room)
    if m:
        return f"air_{m.group(1)}"
    if rir_list_room.startswith("RVB2014_"):
        return rir_list_room
    m = re.match(r"(RWCP_(?:circle|cirline)_[a-z0-9]+)", rir_list_room)
    if m:
        return m.group(1)
    if "type4" in filename:
        return "RWCP_type4"
    return None


def real_room_split(room: str) -> str:
    return REAL_ROOM_SPLIT.get(room, "train")


# --- index building -------------------------------------------------------------


def _librispeech(split: str) -> dict[str, Any]:
    root = paths.LIBRISPEECH
    spk = splits.speakers(split, root)
    utts = []
    for s in spk:
        for chap_dir in sorted((root / s.subset / s.id).iterdir(), key=lambda p: int(p.name)):
            trans = chap_dir / f"{s.id}-{chap_dir.name}.trans.txt"
            texts = dict(line.split(" ", 1) for line in trans.read_text().splitlines() if line.strip())
            for f in sorted(chap_dir.glob("*.flac")):
                sr, frames, ch = audio_info(f)
                if sr != 16000 or ch != 1:
                    raise ValueError(f"unexpected format {f}")
                utts.append({"id": f.stem, "speaker": s.id, "chapter": chap_dir.name, "path": str(f.relative_to(root)), "samples": frames, "text": texts[f.stem].strip()})
    return {"split": split, "subsets": list(splits.SPLIT_SUBSETS[split]), "speakers": {s.id: s.sex for s in spk}, "utterances": utts}


def _musan_licences(d: Path) -> dict[str, str]:
    """Map MUSAN file id -> licence text block (for the no-derivatives check)."""
    lic = (d / "LICENSE").read_text(errors="replace")
    out: dict[str, str] = {}
    for block in re.split(r"\n=+\n", lic):
        for fid in re.findall(r"(music-[a-z-]+-\d{4})", block):
            out[fid] = block
    return out


def _aux() -> dict[str, Any]:
    entries: dict[str, list[dict[str, Any]]] = {"ambience": [], "events": [], "music": [], "usgov": [], "rir_real": [], "rir_slr26": []}
    # DEMAND ambience: one entry per environment and channel, whole environments per split.
    for env in DEMAND_ENVS:
        cands = sorted(p for p in DEMAND_ROOT.glob(f"{env}_16k-*") if p.is_dir())
        d = cands[0] / env
        for ch in range(1, 17):
            f = d / f"ch{ch:02d}.wav"
            _, frames, _ = audio_info(f)
            entries["ambience"].append({"source": "demand", "key": f"{env}-ch{ch:02d}", "path": str(f), "start": 0, "end": frames, "channel": 0, "split": demand_env_split(env), "room": f"demand-{env}"})
    # SLR28 isotropic noises, split with their room.
    for line in (SLR28_REAL / "noise_list").read_text().splitlines():
        parts = line.split()
        room_link, rel = parts[5], parts[6]
        f = paths.DATA / "openslr28" / rel
        room = real_room_key(room_link, f.name) or room_link
        _, frames, nch = audio_info(f)
        entries["ambience"].append({"source": "slr28-isotropic", "key": f.stem, "path": str(f), "start": 0, "end": frames, "channel": 0, "split": real_room_split(room), "room": room})
    # MUSAN noise events (free-sound + sound-bible). SLR28 point-source noises are
    # a MUSAN subset and are not used separately.
    for sub in ("free-sound", "sound-bible"):
        for f in sorted((MUSAN_NM / "noise" / sub).glob("*.wav")):
            _, frames, _ = audio_info(f)
            entries["events"].append({"source": f"musan-{sub}", "key": f.stem, "path": str(f), "start": 0, "end": frames, "split": split_by_hash(f.stem)})
    # MUSAN music without vocals and without a no-derivatives licence.
    for d in sorted(p for p in (MUSAN_NM / "music").iterdir() if p.is_dir()):
        ann = {l.split()[0]: l.split() for l in (d / "ANNOTATIONS").read_text().splitlines() if l.strip()}
        lic = _musan_licences(d)
        for f in sorted(d.glob("*.wav")):
            a = ann.get(f.stem)
            if a is None or a[2] != "N":
                continue
            block = lic.get(f.stem, "")
            if re.search(r"NoDeriv|No Deriv|\bND\b", block):
                continue
            _, frames, _ = audio_info(f)
            entries["music"].append({"source": f"musan-{d.name}", "key": f.stem, "path": str(f), "start": 0, "end": frames, "split": split_by_hash(f.stem)})
    # MUSAN us-gov speech (public domain; not LibriVox).
    for f in sorted(MUSAN_USGOV.glob("*.wav")):
        _, frames, _ = audio_info(f)
        entries["usgov"].append({"source": "musan-us-gov", "key": f.stem, "path": str(f), "start": 0, "end": frames, "split": split_by_hash(f.stem)})
    # Real RIRs: SLR28 (RWCP, REVERB 2014, AIR) and BUT ReverbDB.
    for line in (SLR28_REAL / "rir_list").read_text().splitlines():
        parts = line.split()
        room_id, rel = parts[3], parts[4]
        f = paths.DATA / "openslr28" / rel
        room = real_room_key(room_id, f.name)
        if room is None:
            continue
        entries["rir_real"].append({"source": "slr28-real", "key": f.stem, "path": str(f), "room": room, "split": real_room_split(room)})
    for f in sorted(BUT_ROOT.glob("*/*/*/*/RIR/*.wav")):
        room = "BUT_" + f.relative_to(BUT_ROOT).parts[0]
        entries["rir_real"].append({"source": "but-reverbdb", "key": str(f.relative_to(BUT_ROOT)), "path": str(f), "room": room, "split": real_room_split(room)})
    # OpenSLR 26 small and medium rooms, distance from the direct-path delay.
    slr = []
    for size in ("smallroom", "mediumroom"):
        for line in (SLR26_ROOT / size / "rir_list").read_text().splitlines():
            parts = line.split()
            room, rel = parts[3], parts[4]
            slr.append((room, str(paths.DATA / "openslr26" / rel)))
    with ProcessPoolExecutor(8) as ex:
        dists = list(ex.map(_slr26_distance, [p for _, p in slr], chunksize=256))
    for (room, p), dist in zip(slr, dists):
        entries["rir_slr26"].append({"source": "slr26", "key": Path(p).stem, "path": p, "room": room, "distance": dist, "split": split_by_hash(room)})
    return entries


def _slr26_distance(p: str) -> float:
    return round(distance_from_delay(load_audio(p)), 3)


def build_index(split_names: list[str], aux: bool = True) -> None:
    paths.require_mount()
    INDEX_DIR.mkdir(parents=True, exist_ok=True)
    for sp in split_names:
        out = INDEX_DIR / f"librispeech-{sp}.json"
        out.write_text(json.dumps(_librispeech(sp)))
        print(f"wrote {out} sha256={sha256_file(out)}")
    if not aux:
        return
    out = INDEX_DIR / "aux.json"
    aux = _aux()
    out.write_text(json.dumps(aux))
    for k, v in aux.items():
        by = {sp: sum(1 for e in v if e["split"] == sp) for sp in ("train", "dev", "test")}
        print(k, len(v), by)
    print(f"wrote {out} sha256={sha256_file(out)}")


def _bank_room(args: tuple[str, int]) -> str:
    split, i = args
    out = BANK_DIR / split / f"room-{i:04d}.npz"
    if out.exists():
        return str(out)
    r = simulate_room(split, i)
    meta = {k: v for k, v in r.items() if k != "rirs"}
    tmp = out.with_suffix(".tmp.npz")
    np.savez(tmp, meta=json.dumps(meta), **r["rirs"])
    tmp.rename(out)
    return str(out)


def build_bank(split: str, workers: int, count: int | None = None) -> None:
    paths.require_mount()
    n = BANK_SIZES[split] if count is None else count
    (BANK_DIR / split).mkdir(parents=True, exist_ok=True)
    with ProcessPoolExecutor(workers) as ex:
        for k, p in enumerate(ex.map(_bank_room, [(split, i) for i in range(n)], chunksize=4)):
            if k % 50 == 0:
                print(k, p, flush=True)
    rooms = []
    for i in range(n):
        with np.load(BANK_DIR / split / f"room-{i:04d}.npz") as z:
            rooms.append(json.loads(str(z["meta"])))
    (BANK_DIR / f"{split}.json").write_text(json.dumps(rooms))
    print(f"bank {split}: {n} rooms")


# --- loading ----------------------------------------------------------------------


@dataclass(frozen=True)
class Utterance:
    id: str
    speaker: str
    chapter: str
    path: Path
    samples: int
    text: str

    @property
    def seconds(self) -> float:
        return self.samples / 16000


def parse_chapters_txt(text: str) -> dict[str, str]:
    """LibriSpeech CHAPTERS.TXT -> {chapter id: project id}."""
    out: dict[str, str] = {}
    for line in text.splitlines():
        if not line.strip() or line.lstrip().startswith(";"):
            continue
        f = [x.strip() for x in line.split("|")]
        if len(f) >= 5:
            out[f[0]] = f[4]
    return out


def _load_json(path: str) -> Any:
    st = Path(path).stat()
    return _load_json_at(path, st.st_mtime_ns, st.st_size)


@lru_cache(maxsize=8)
def _load_json_at(path: str, mtime_ns: int, size: int) -> Any:
    """Cached by path, modification time and size, so a rebuilt index is reread."""
    return json.loads(Path(path).read_text())


class Corpus:
    """Everything one split may use. Construction is cheap; indexes load lazily."""

    def __init__(self, split: str, index_dir: Path = INDEX_DIR, bank_dir: Path = BANK_DIR, align_dir: Path | None = None):
        if split not in splits.SPLIT_SUBSETS:
            raise ValueError(f"unknown split {split!r}")
        self.split = split
        self.index_dir = index_dir
        self.bank_dir = bank_dir
        from .forced import ALIGN_DIR

        self.align_dir = align_dir or ALIGN_DIR

    def alignment(self, utt_id: str) -> list[list[Any]] | None:
        """Word intervals [[word, start_s, end_s], ...] of a LibriSpeech utterance."""
        from .forced import load_alignments

        return load_alignments(self.split, self.align_dir).get(utt_id)

    @cached_property
    def _libri(self) -> dict[str, Any]:
        d = _load_json(str(self.index_dir / f"librispeech-{self.split}.json"))
        want = list(splits.SPLIT_SUBSETS[self.split])
        if d.get("subsets") != want:
            raise RuntimeError(f"stale LibriSpeech index for {self.split}: built for {d.get('subsets')}, split is {want}; rebuild with prep index")
        return d

    @cached_property
    def sex(self) -> dict[str, str]:
        return dict(self._libri["speakers"])

    @cached_property
    def speakers(self) -> list[str]:
        return sorted(self.sex, key=int)

    @cached_property
    def utterances(self) -> dict[str, list[Utterance]]:
        out: dict[str, list[Utterance]] = {s: [] for s in self.speakers}
        for u in self._libri["utterances"]:
            out[u["speaker"]].append(Utterance(u["id"], u["speaker"], u["chapter"], paths.LIBRISPEECH / u["path"], u["samples"], u["text"]))
        return out

    @cached_property
    def subset(self) -> dict[str, str]:
        """speaker -> LibriSpeech subset (e.g. dev-clean, dev-other)."""
        out = {}
        for u in self._libri["utterances"]:
            out.setdefault(u["speaker"], u.get("subset") or Path(u["path"]).parts[0])
        return out

    @cached_property
    def utterance_by_id(self) -> dict[str, Utterance]:
        return {u.id: u for us in self.utterances.values() for u in us}

    @cached_property
    def _projects(self) -> dict[str, str]:
        """chapter id -> LibriVox project id. Different chapters of one project
        are probably one recording setup (same microphone and room)."""
        explicit = {u["chapter"]: str(u["project"]) for u in self._libri["utterances"] if "project" in u}
        if explicit:
            return explicit
        return parse_chapters_txt((paths.LIBRISPEECH / "CHAPTERS.TXT").read_text(errors="replace"))

    def project(self, u: Utterance) -> str:
        return self._projects.get(u.chapter, f"chapter-{u.chapter}")

    @cached_property
    def _aux(self) -> dict[str, list[dict[str, Any]]]:
        aux = _load_json(str(self.index_dir / "aux.json"))
        return {k: [e for e in v if e["split"] == self.split] for k, v in aux.items()}

    def aux(self, kind: str) -> list[dict[str, Any]]:
        return self._aux[kind]

    @cached_property
    def slr26_by_room(self) -> dict[str, list[dict[str, Any]]]:
        out: dict[str, list[dict[str, Any]]] = {}
        for e in self._aux["rir_slr26"]:
            out.setdefault(e["room"], []).append(e)
        return out

    @cached_property
    def bank(self) -> list[dict[str, Any]]:
        return _load_json(str(self.bank_dir / f"{self.split}.json"))

    def bank_rirs(self, index: int) -> dict[str, np.ndarray]:
        return _bank_npz(str(self.bank_dir / self.split / f"room-{index:04d}.npz"))

    def index_hashes(self) -> dict[str, str]:
        out = {
            "librispeech": _file_hash(str(self.index_dir / f"librispeech-{self.split}.json")),
            "aux": _file_hash(str(self.index_dir / "aux.json")),
            "bank": _file_hash(str(self.bank_dir / f"{self.split}.json")),
            "alignment": _file_hash(str(self.align_dir / f"{self.split}.jsonl")),
        }
        chapters = paths.LIBRISPEECH / "CHAPTERS.TXT"
        if not any("project" in u for u in self._libri["utterances"][:1]) and chapters.exists():
            out["chapters_txt"] = _file_hash(str(chapters))
        return out


def _file_hash(path: str) -> str:
    st = Path(path).stat()
    return _file_hash_at(path, st.st_mtime_ns, st.st_size)


@lru_cache(maxsize=64)
def _file_hash_at(path: str, mtime_ns: int, size: int) -> str:
    return sha256_file(Path(path))


@lru_cache(maxsize=256)
def _bank_npz(path: str) -> dict[str, np.ndarray]:
    with np.load(path) as z:
        return {k: z[k] for k in z.files if k != "meta"}


@lru_cache(maxsize=2048)
def load_rir(path: str) -> np.ndarray:
    """A real or OpenSLR 26 RIR, first channel, normalised."""
    return normalise_rir(load_audio(path))
