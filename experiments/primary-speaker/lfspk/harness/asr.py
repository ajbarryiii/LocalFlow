"""Parakeet TDT 0.6B v2 transcription cache with word timestamps (DESIGN.md section 7).

    ./python-nemo -m lfspk.harness.asr run WORKLIST.jsonl OUT.jsonl [--batch 16]

WORKLIST lines: {"key": str, "path": audio file} (16 kHz mono). OUT lines:
{"key", "text", "words": [[word, start_s, end_s], ...]}. Resumable: keys already
in OUT are skipped. Runs under a shared GPU lease; the per-process memory
fraction comes from AGENT_JOBS_VRAM_FRACTION. Greedy TDT decoding, FP32, the
model's default decoding config except compute_timestamps.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import time
from pathlib import Path
from typing import Any, Iterable, Sequence

import numpy as np

from .. import paths
from .util import load_audio, sha256_file


def load_model(device: str = "cuda") -> Any:
    import torch
    from nemo.collections.asr.models import ASRModel

    if device == "cuda":
        frac = os.environ.get("AGENT_JOBS_VRAM_FRACTION")
        if frac:
            torch.cuda.set_per_process_memory_fraction(float(frac))
    model = ASRModel.restore_from(str(paths.PARAKEET_V2_NEMO), map_location=device)
    model.eval()
    return model


def words_of(hyp: Any) -> list[list[Any]]:
    ts = getattr(hyp, "timestamp", None) or {}
    out = []
    for w in ts.get("word", []):
        out.append([str(w["word"]), round(float(w["start"]), 3), round(float(w["end"]), 3)])
    return out


def transcribe(model: Any, audios: Sequence[np.ndarray], batch_size: int = 16) -> list[dict[str, Any]]:
    import torch

    with torch.inference_mode():
        hyps = model.transcribe(list(audios), batch_size=batch_size, timestamps=True, verbose=False)
    if isinstance(hyps, tuple):
        hyps = hyps[0]
    return [{"text": h.text, "words": words_of(h)} for h in hyps]


DECODING = "greedy TDT, fp32, timestamps, length-sorted batches"


def cache_identity() -> dict[str, Any]:
    import nemo

    return {"model": str(paths.PARAKEET_V2_NEMO), "model_sha256": sha256_file(paths.PARAKEET_V2_NEMO), "decoding": DECODING,
            "nemo": getattr(nemo, "__version__", "unknown")}


def check_resume(out: Path, identity: dict[str, Any], items: list[dict[str, Any]]) -> set[str]:
    """Keys already transcribed for exactly these inputs and this configuration.
    A cache written by another model, decoding or NeMo version, or whose entries
    were made from different audio bytes, is refused (eval r1 #9)."""
    from .forced import read_jsonl, truncate_incomplete_tail

    meta_path = out.parent / (out.stem + ".meta.json")
    if not out.exists():
        return set()
    if not meta_path.exists() or json.loads(meta_path.read_text()) != identity:
        raise SystemExit(f"{out}: existing cache has another (or no) identity; refusing to mix configurations")
    truncate_incomplete_tail(out)
    want = {it["key"]: it["audio_sha256"] for it in items}
    done = set()
    for r in read_jsonl(out):
        if r["key"] in want and r.get("audio_sha256") != want[r["key"]]:
            raise SystemExit(f"{out}: cached {r['key']} was made from different audio; refusing to resume")
        done.add(r["key"])
    return done


def run(worklist: Path, out: Path, batch_size: int, chunk: int = 256) -> None:
    items = [json.loads(l) for l in worklist.read_text().splitlines() if l.strip()]
    for it in items:
        it["audio_sha256"] = sha256_file(Path(it["path"]))
    identity = cache_identity()
    done = check_resume(out, identity, items)
    todo = [it for it in items if it["key"] not in done]
    print(f"{len(items)} items, {len(done)} done, {len(todo)} to do", flush=True)
    if not todo:
        return
    (out.parent / (out.stem + ".meta.json")).write_text(json.dumps(identity, indent=1))
    model = load_model()
    t0 = time.time()
    with open(out, "a") as f:
        for s in range(0, len(todo), chunk):
            part = todo[s : s + chunk]
            audios = [load_audio(it["path"]) for it in part]
            order = sorted(range(len(part)), key=lambda i: audios[i].size)  # similar lengths per batch
            hyps = transcribe(model, [audios[i] for i in order], batch_size)
            res = [None] * len(part)
            for i, r in zip(order, hyps):
                res[i] = r
            for it, r in zip(part, res):
                f.write(json.dumps({"key": it["key"], "audio_sha256": it["audio_sha256"], **r}) + "\n")
            f.flush()
            print(f"{s + len(part)}/{len(todo)} {time.time() - t0:.0f}s", flush=True)


def read_cache(path: Path) -> dict[str, dict[str, Any]]:
    from .forced import read_jsonl

    return {r["key"]: r for r in read_jsonl(Path(path))}


def main(argv: Iterable[str] | None = None) -> None:
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    r = sub.add_parser("run")
    r.add_argument("worklist", type=Path)
    r.add_argument("out", type=Path)
    r.add_argument("--batch", type=int, default=16)
    a = ap.parse_args(list(argv) if argv is not None else None)
    paths.require_mount()
    if a.cmd == "run":
        run(a.worklist, a.out, a.batch)


if __name__ == "__main__":
    sys.exit(main())
