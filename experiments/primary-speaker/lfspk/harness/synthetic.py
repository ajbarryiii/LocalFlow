"""Synthetic corpus for W0 tests and smoke runs: invented signals only, no real audio.

Speech is imitated by noise bursts with a known on/off pattern, amplitude-
modulated at a speaker-specific pitch so speakers differ. Rooms are synthetic
exponential-decay RIRs. Everything is written to a temporary directory.
"""

from __future__ import annotations

import json
import os
import tempfile
from pathlib import Path

import numpy as np
import soundfile as sf

FS = 16000


def burst_signal(rng: np.random.Generator, pattern: list[tuple[float, float]], f0: float, total: float, level: float = 0.1) -> np.ndarray:
    """Bursts at the given (start, end) seconds, low-level background elsewhere."""
    n = int(total * FS)
    x = rng.standard_normal(n) * level * 1e-3
    t = np.arange(n) / FS
    for s, e in pattern:
        a, b = int(s * FS), int(e * FS)
        x[a:b] += rng.standard_normal(b - a) * level * (0.6 + 0.4 * np.sin(2 * np.pi * f0 * t[a:b]))
    return x.astype(np.float32)


def speech_like(rng: np.random.Generator, seconds: float, f0: float) -> tuple[np.ndarray, list[tuple[float, float]]]:
    pattern, t = [], 0.25
    while t < seconds - 0.6:
        dur = rng.uniform(0.3, 1.2)
        pattern.append((t, min(t + dur, seconds - 0.25)))
        t += dur + rng.uniform(0.12, 0.6)
    return burst_signal(rng, pattern, f0, seconds), pattern


def synthetic_rir(rng: np.random.Generator, t60: float, direct_delay: int = 40, drr_scale: float = 0.3) -> np.ndarray:
    n = int(t60 * FS)
    h = np.zeros(direct_delay + n, dtype=np.float32)
    h[direct_delay] = 1.0
    tail = rng.standard_normal(n) * np.exp(-6.9 * np.arange(n) / n) * drr_scale * 0.05
    h[direct_delay + 1 :] += tail[: n - 1].astype(np.float32)
    return h


def build_corpus(root: Path, n_speakers: int = 6, chapters: int = 2, utts_per_chapter: int = 8, seed: int = 0):
    """Write a synthetic LibriSpeech-like index, aux index and RIR bank for split 'dev'."""
    from lfspk.harness.corpora import Corpus

    rng = np.random.default_rng(seed)
    audio = root / "audio"
    audio.mkdir(parents=True)
    index = root / "index"
    index.mkdir()
    bank = root / "bank"
    (bank / "dev").mkdir(parents=True)
    utts, speakers, aligned = [], {}, []
    for k in range(n_speakers):
        spk = str(100 + k)
        speakers[spk] = "F" if k % 2 == 0 else "M"
        for c in range(chapters + (1 if k == 1 else 0) if k != n_speakers - 1 else 1):
            ch = str(100 * (k + 1) + c)  # globally unique, as in LibriSpeech
            for u in range(utts_per_chapter):
                x, pattern = speech_like(rng, float(rng.uniform(3.2, 9.0)), 3 + k)
                p = audio / f"{spk}-{ch}-{u:04d}.flac"
                sf.write(p, x, FS, subtype="PCM_16")
                # The two chapters of speaker 100 are different projects; others share one.
                project = f"p{spk}-{ch}" if spk == "100" else f"p{spk}"
                utts.append({"id": p.stem, "speaker": spk, "chapter": ch, "project": project, "path": str(p), "samples": x.size, "text": f"word{k} alpha beta gamma {u}"})
                # The bursts are the "words": an exact synthetic alignment.
                aligned.append({"id": p.stem, "method": "synthetic", "words": [[f"w{i}", round(a, 3), round(b, 3)] for i, (a, b) in enumerate(pattern)]})
    align = root / "align"
    align.mkdir()
    (align / "dev.jsonl").write_text("".join(json.dumps(r) + "\n" for r in aligned))
    (index / "librispeech-dev.json").write_text(json.dumps({"split": "dev", "subsets": ["dev-clean", "dev-other"], "speakers": speakers, "utterances": utts}))
    aux = {k: [] for k in ("ambience", "events", "music", "usgov", "rir_real", "rir_slr26")}
    # Non-stationary ambience: the level steps by 0/-12/+6 dB every 2 s.
    steps = np.repeat(np.tile([1.0, 0.25, 2.0], 7)[:20], 2 * FS)
    amb = (rng.standard_normal(FS * 40) * 0.01 * steps).astype(np.float32)
    sf.write(audio / "amb.wav", amb, FS, subtype="PCM_16")
    aux["ambience"].append({"source": "synthetic", "key": "amb", "path": str(audio / "amb.wav"), "start": 0, "end": amb.size, "channel": 0, "split": "dev"})
    ev = (rng.standard_normal(FS * 3) * 0.05).astype(np.float32)
    sf.write(audio / "event.wav", ev, FS, subtype="PCM_16")
    aux["events"].append({"source": "synthetic", "key": "event", "path": str(audio / "event.wav"), "start": 0, "end": ev.size, "split": "dev"})
    t = np.arange(FS * 30) / FS
    mus = (0.05 * np.sin(2 * np.pi * 220 * t) * (1 + 0.5 * np.sin(2 * np.pi * 0.5 * t))).astype(np.float32)
    sf.write(audio / "music.wav", mus, FS, subtype="PCM_16")
    aux["music"].append({"source": "synthetic", "key": "music", "path": str(audio / "music.wav"), "start": 0, "end": mus.size, "split": "dev"})
    for j in range(3):
        h = synthetic_rir(rng, 0.4 + 0.1 * j, direct_delay=60 + 30 * j)
        sf.write(audio / f"real{j}.wav", h, FS, subtype="FLOAT")
        aux["rir_real"].append({"source": "synthetic", "key": f"real{j}", "path": str(audio / f"real{j}.wav"), "room": f"r{j}", "split": "dev"})
        aux["rir_slr26"].append({"source": "slr26", "key": f"sim{j}", "path": str(audio / f"real{j}.wav"), "room": f"small-Room00{j}", "distance": 1.5 + j, "split": "dev"})
    h = synthetic_rir(rng, 0.3, direct_delay=20)
    sf.write(audio / "near.wav", h, FS, subtype="FLOAT")
    aux["rir_real"].append({"source": "slr28-real", "key": "RVB2014_type1_rir_synth_near_angla", "path": str(audio / "near.wav"), "room": "r9", "split": "dev"})
    aux["rir_real"].append({"source": "slr28-real", "key": "RVB2014_type1_rir_synth_far_angla", "path": str(audio / "real1.wav"), "room": "r9", "split": "dev"})
    aux["rir_slr26"].append({"source": "slr26", "key": "simnear", "path": str(audio / "near.wav"), "room": "small-Room009", "distance": 0.4, "split": "dev"})
    (index / "aux.json").write_text(json.dumps(aux))
    rooms = []
    from lfspk.harness.rirs import FAR_BANDS, normalise_rir

    for i in range(3):
        roles = {"target_builtin": 0.4, "target_headset": 0.03, "laptop_speaker": 0.15}
        roles.update({f"far_{k}": (lo + hi) / 2 for k, (lo, hi) in enumerate(FAR_BANDS)})
        rirs = {name: normalise_rir(synthetic_rir(rng, 0.3, drr_scale=d)) for name, d in roles.items()}
        meta = {"split": "dev", "index": i, "dims": [5, 4, 3], "t60": 0.3, "mic": [1, 1, 1], "distance": roles, "drr_db": {}}
        np.savez(bank / "dev" / f"room-{i:04d}.npz", meta=json.dumps(meta), **rirs)
        rooms.append(meta)
    (bank / "dev.json").write_text(json.dumps(rooms))
    return Corpus("dev", index_dir=index, bank_dir=bank, align_dir=align)


class SyntheticCorpus:
    """Context manager: a temporary synthetic corpus for split 'dev'."""

    def __enter__(self):
        # A few MB of invented audio: keep it off the busy data disk (TMPDIR there
        # made the test suite take minutes under shared I/O load).
        fast = os.environ.get("LFSPK_FAST_TMP", "/tmp")
        self._tmp = tempfile.TemporaryDirectory(dir=fast if os.path.isdir(fast) else None)
        self.root = Path(self._tmp.name)
        self.corpus = build_corpus(self.root)
        return self.corpus

    def __exit__(self, *exc):
        self._tmp.cleanup()
