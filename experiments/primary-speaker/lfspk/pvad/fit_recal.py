"""Fit the population value of the A8 recalibration statistic on train speakers
(DESIGN.md section 8). Train split only.

    ./python -m lfspk.pvad.fit_recal --checkpoint RUNS/W3/train/<run>/final.pt [--speakers 60] [--workers 6]

For the first `speakers` target-eligible train speakers in sha256 order, the
first 10 bank utterances (enrollment pool, `bank_utterances` order) are
rendered by W0 as clean built-in S0 dictations (the bank's clean seeds) and
enrolled; the next 5 are rendered the same way and scored with that profile,
as a user's own later dictations. population = mean over speakers of the mean
per-dictation statistic (`scorer.fit_recal_population`). Output:
RUNS/W3/recal/<run>.json, tied to the checkpoint's SHA-256.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import time
from multiprocessing import get_context
from pathlib import Path

from lfspk import paths

from .bank_build import _render
from .enrollment import bank_utterances, librispeech_partitions, target_eligible
from .harness_scorer import file_sha256, make
from .scorer import fit_recal_population

OUT = paths.RUNS / "W3" / "recal"
K_ENROLL, N_EVAL = 10, 5


def fit_speakers(n: int) -> list[tuple[str, list[str]]]:
    parts = librispeech_partitions("train")
    elig = sorted((s for s, p in parts.items() if target_eligible(p)),
                  key=lambda s: hashlib.sha256(f"w3-recal/{s}".encode()).hexdigest())
    out = []
    for s in elig:
        utts = bank_utterances(parts[s], 40)
        if len(utts) >= K_ENROLL + N_EVAL:
            out.append((s, utts[: K_ENROLL + N_EVAL]))
        if len(out) == n:
            break
    return out


def fit(checkpoint: Path, n_speakers: int = 60, workers: int = 6) -> Path:
    scorer = make(str(checkpoint))
    items = fit_speakers(n_speakers)
    jobs = [(s, u, "builtin") for s, utts in items for u in utts]
    audio: dict[str, object] = {}
    with get_context("spawn").Pool(workers) as pool:
        for spk, utt, _dev, clean, _dirty, _info in pool.imap(_render, jobs, chunksize=4):
            audio[utt] = clean
    users = []
    for s, utts in items:
        prof = scorer.enroll([audio[u] for u in utts[:K_ENROLL]])
        users.append((prof, [audio[u] for u in utts[K_ENROLL:]]))
    pop = fit_recal_population(scorer, users)
    OUT.mkdir(parents=True, exist_ok=True)
    path = OUT / f"{Path(checkpoint).parent.name}.json"
    path.write_text(json.dumps({"population": pop, "checkpoint": str(checkpoint), "checkpoint_sha256": file_sha256(checkpoint),
                                "speakers": [s for s, _ in items], "k_enroll": K_ENROLL, "n_eval": N_EVAL,
                                "gate": scorer.gate, "quantile": 0.10, "split": "train",
                                "created_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())}, indent=1))
    return path


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--checkpoint", required=True, type=Path)
    ap.add_argument("--speakers", type=int, default=60)
    ap.add_argument("--workers", type=int, default=6)
    a = ap.parse_args()
    paths.require_mount()
    print(fit(a.checkpoint, a.speakers, a.workers))


if __name__ == "__main__":
    main()
