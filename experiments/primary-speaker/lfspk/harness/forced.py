"""Word-level forced alignment of LibriSpeech and the frame labels derived from it
(DESIGN.md section 5, after mix review r4).

    ./python -m lfspk.harness.forced run --split dev [--limit N]     # GPU shared lease
    ./python -m lfspk.harness.forced coverage

Aligner: CTC forced alignment of the reference transcript
(torchaudio.functional.forced_align) on the emissions of torchaudio's
WAV2VEC2_ASR_BASE_960H (fairseq wav2vec 2.0 base fine-tuned on LibriSpeech
960 h, MIT licence), 20 ms frames. Output, one JSON line per utterance in
ALIGN_DIR/<split>.jsonl: {"id", "method", "words": [[word, start_s, end_s], ...]}.

Frame activity: gaps between consecutive words shorter than GAP_S are merged,
and a 10 ms frame is active iff it intersects a merged interval padded by PAD_S
on each side; everything else (pauses of GAP_S or more, room tone, padding) is
inactive. Independent of level, dither and noise by construction.
"""

from __future__ import annotations

import argparse
import json
import math
import os
import sys
import time
from functools import lru_cache
from pathlib import Path
from typing import Any, Sequence

import numpy as np

from .. import paths
from ..api import FRAME_SAMPLES, SAMPLE_RATE, frame_count

ALIGN_DIR = Path(os.environ.get("LFSPK_ALIGN_DIR", str(paths.DATA / "harness" / "align" / "v1")))
# Pre-registered label parameters (DESIGN.md section 5). CTC alignments are
# "peaky": against Parakeet word spans on a 40-utterance dev smoke, CTC word
# ends were a median 47 ms early and 95 % of consecutive words had a CTC gap of
# 40 ms or more (Parakeet: 19 %). Gaps between consecutive words shorter than
# GAP_S are merged as within-phrase; every interval is then padded by PAD_S (two
# CTC frames). Known cost: a genuine target pause under 200 ms becomes speech,
# which inflates the overlap class (DESIGN.md section 5; a no-merge variant is
# reported for sensitivity). All boundary arithmetic is in integer milliseconds.
PAD_S = 0.04
GAP_S = 0.2
NO_MERGE_GAP_S = 0.0  # the sensitivity variant
METHOD = "ctc-wav2vec2-base-960h"
FRAME_S = FRAME_SAMPLES / SAMPLE_RATE


def _ms(t: float) -> int:
    return int(round(float(t) * 1000.0))


def merge_gaps_ms(words: Sequence[Sequence[Any]], gap_s: float = GAP_S) -> list[tuple[int, int]]:
    """Word intervals in integer milliseconds, time-ordered, with gaps strictly
    shorter than gap_s merged (a gap of exactly gap_s stays a gap)."""
    gap = _ms(gap_s)
    out: list[list[int]] = []
    for w in sorted(words, key=lambda w: _ms(w[1])):
        s, e = _ms(w[1]), _ms(w[2])
        if out and s - out[-1][1] < gap:
            out[-1][1] = max(out[-1][1], e)
        else:
            out.append([s, e])
    return [(a, b) for a, b in out]


def merge_gaps(words: Sequence[Sequence[Any]], gap_s: float = GAP_S) -> list[tuple[float, float]]:
    return [(a / 1000.0, b / 1000.0) for a, b in merge_gaps_ms(words, gap_s)]


def words_to_frames(words: Sequence[Sequence[Any]], n_frames: int, pad_s: float = PAD_S, gap_s: float = GAP_S) -> np.ndarray:
    """Boolean activity per 10 ms frame: frame i covers [10 i, 10 (i + 1)) ms and
    is active iff it intersects some merged interval padded to
    [start - pad, end + pad] (gaps under gap_s merged first). Integer ms."""
    act = np.zeros(n_frames, dtype=bool)
    pad = _ms(pad_s)
    step = int(round(FRAME_S * 1000))
    for s0, e0 in merge_gaps_ms(words, gap_s):
        s, e = s0 - pad, e0 + pad
        if e <= s:
            continue
        f0 = max(0, s // step)
        f1 = min(n_frames, -(-e // step))
        if f1 > f0:
            act[f0:f1] = True
    return act


def activity_from_alignment(words: Sequence[Sequence[Any]], num_samples: int, pad_s: float = PAD_S, gap_s: float = GAP_S) -> np.ndarray:
    return words_to_frames(words, frame_count(num_samples), pad_s, gap_s)


# --- aligner ---------------------------------------------------------------------------


def _bundle():
    import torchaudio

    return torchaudio.pipelines.WAV2VEC2_ASR_BASE_960H


def load_aligner(device: str = "cuda"):
    import torch

    if device == "cuda":
        frac = os.environ.get("AGENT_JOBS_VRAM_FRACTION")
        if frac:
            torch.cuda.set_per_process_memory_fraction(float(frac))
    b = _bundle()
    model = b.get_model().to(device).eval()
    labels = b.get_labels()
    return model, {c: i for i, c in enumerate(labels)}, device


def transcript_tokens(text: str, dictionary: dict[str, int]) -> tuple[list[str], list[int]]:
    """Words of a LibriSpeech transcript and the CTC target sequence
    (characters, words separated by '|'). Characters outside the vocabulary
    (and the blank and separator symbols themselves) are dropped from the
    targets; a word left with none is dropped. LibriSpeech transcripts contain
    only A-Z, apostrophe and spaces, so this only guards against surprises."""
    valid = {c for c, i in dictionary.items() if i != 0 and c != "|"}  # index 0 is the CTC blank
    words = [w for w in text.upper().split() if any(c in valid for c in w)]
    targets: list[int] = []
    for i, w in enumerate(words):
        if i:
            targets.append(dictionary["|"])
        targets += [dictionary[c] for c in w if c in valid]
    return words, targets


def align_one(model, dictionary: dict[str, int], device: str, wave: np.ndarray, text: str) -> list[list[Any]]:
    import torch
    import torchaudio.functional as F

    words, targets = transcript_tokens(text, dictionary)
    if not words:
        raise ValueError("transcript has no alignable word")
    with torch.inference_mode():
        x = torch.from_numpy(wave).to(device)[None]
        emission, _ = model(x)
        emission = torch.log_softmax(emission, dim=-1)
        T = emission.shape[1]
        if len(targets) > T:
            raise ValueError("transcript longer than the emission")
        aligned, scores = F.forced_align(emission, torch.tensor([targets], dtype=torch.int32, device=device), blank=0)
        spans = F.merge_tokens(aligned[0].cpu(), scores[0].exp().cpu())
    stride = wave.size / T / SAMPLE_RATE  # seconds per emission frame (about 0.02)
    return group_word_spans([(sp.token, sp.start, sp.end) for sp in spans], words, dictionary["|"], stride)


def group_word_spans(spans: Sequence[tuple[int, int, int]], words: Sequence[str], sep: int, stride: float) -> list[list[Any]]:
    """Merge character spans (token, start frame, end frame exclusive) into word
    intervals in seconds, splitting at the word-separator token."""
    out: list[list[Any]] = []
    cur: list[int] = []
    for tok, start, end in spans:
        if tok == sep:
            if cur:
                out.append(cur)
                cur = []
            continue
        cur = [start, end] if not cur else [cur[0], end]
    if cur:
        out.append(cur)
    if len(out) != len(words):
        raise ValueError(f"aligned {len(out)} of {len(words)} words")
    return [[w, round(a * stride, 3), round(b * stride, 3)] for w, (a, b) in zip(words, out)]


def run(split: str, limit: int | None) -> None:
    from .corpora import Corpus
    from .util import load_audio

    paths.require_mount()
    ALIGN_DIR.mkdir(parents=True, exist_ok=True)
    out = ALIGN_DIR / f"{split}.jsonl"
    done = set()
    if out.exists():
        truncate_incomplete_tail(out)
        done = {r["id"] for r in read_jsonl(out)}
    c = Corpus(split)
    utts = [u for s in c.speakers for u in c.utterances[s] if u.id not in done]
    if limit:
        utts = utts[:limit]
    model, dictionary, device = load_aligner()
    meta = {"method": METHOD, "pad_s": PAD_S, "gap_s": GAP_S, "torchaudio_bundle": "WAV2VEC2_ASR_BASE_960H", "split": split}
    (ALIGN_DIR / f"{split}.meta.json").write_text(json.dumps(meta, indent=1))
    t0, failed = time.time(), 0
    # Reading FLAC from the shared disk dominates (about 0.1 s per utterance vs
    # 0.02 s to align), so audio is prefetched by a small thread pool, one chunk
    # ahead; output order and content are unchanged.
    from concurrent.futures import ThreadPoolExecutor

    chunk = 64
    with open(out, "a") as f, ThreadPoolExecutor(max_workers=8) as pool:
        nxt = [pool.submit(load_audio, u.path) for u in utts[:chunk]]
        for c0 in range(0, len(utts), chunk):
            cur, part = nxt, utts[c0 : c0 + chunk]
            nxt = [pool.submit(load_audio, u.path) for u in utts[c0 + chunk : c0 + 2 * chunk]]
            for u, fut in zip(part, cur):
                try:
                    words = align_one(model, dictionary, device, fut.result(), u.text)
                    rec = {"id": u.id, "method": METHOD, "words": words}
                except Exception as e:  # recorded, then covered by the Parakeet fallback
                    failed += 1
                    rec = {"id": u.id, "method": "failed", "error": str(e)[:200], "words": []}
                f.write(json.dumps(rec) + "\n")
            f.flush()
            if (c0 // chunk) % 30 == 0:
                print(f"{split} {c0 + len(part)}/{len(utts)} failed={failed} {time.time() - t0:.0f}s", flush=True)
    print(f"{split}: {len(utts)} aligned, {failed} failed, {time.time() - t0:.0f}s")


def read_jsonl(path: Path) -> list[dict[str, Any]]:
    """Records of an append-only JSONL file. An incomplete final line (an
    interrupted append) is dropped with a warning; any other malformed line raises."""
    text = Path(path).read_text()
    lines = text.split("\n")
    out: list[dict[str, Any]] = []
    for k, line in enumerate(lines):
        if not line.strip():
            continue
        try:
            out.append(json.loads(line))
        except json.JSONDecodeError:
            if k == len(lines) - 1:  # no trailing newline: the last append was cut off
                print(f"warning: dropping an incomplete final record of {path}", file=sys.stderr)
                continue
            raise
    return out


def truncate_incomplete_tail(path: Path) -> int:
    """Before appending: cut an incomplete final record so the file stays valid. Returns bytes removed."""
    p = Path(path)
    if not p.exists():
        return 0
    data = p.read_bytes()
    if not data or data.endswith(b"\n"):
        return 0
    keep = data.rfind(b"\n") + 1
    p.write_bytes(data[:keep])
    print(f"warning: removed an incomplete final record ({len(data) - keep} bytes) from {p}", file=sys.stderr)
    return len(data) - keep


@lru_cache(maxsize=4)
def _load(path: str, mtime_ns: int) -> dict[str, list[list[Any]]]:
    """id -> word intervals; the last record of an id wins (a fallback after a
    failure). Failed or empty records are absent."""
    last: dict[str, dict[str, Any]] = {}
    for r in read_jsonl(Path(path)):
        last[r["id"]] = r
    return {i: r["words"] for i, r in last.items() if r["method"] != "failed" and r["words"]}


def load_alignments(split: str, align_dir: Path = ALIGN_DIR) -> dict[str, list[list[Any]]]:
    p = align_dir / f"{split}.jsonl"
    return _load(str(p), p.stat().st_mtime_ns)


def coverage(splits_: Sequence[str] = ("train", "dev", "test")) -> dict[str, Any]:
    """Counts only (no alignment content), so it is safe on the sealed test split."""
    from .corpora import Corpus

    res = {}
    for sp in splits_:
        c = Corpus(sp)
        ids = {u.id for us in c.utterances.values() for u in us}
        p = ALIGN_DIR / f"{sp}.jsonl"
        methods: dict[str, int] = {}
        if p.exists():
            last = {r["id"]: (r["method"] if r["words"] or r["method"] == "failed" else "failed") for r in read_jsonl(p)}
            for i in ids:
                m = last.get(i, "missing")
                methods[m] = methods.get(m, 0) + 1
        else:
            methods["missing"] = len(ids)
        res[sp] = {"utterances": len(ids), "by_method": methods}
    return res


def fallback(split: str) -> None:
    """Pre-registered fallback: utterances whose forced alignment failed get word
    intervals from Parakeet TDT timestamps on the dry utterance (80 ms steps),
    appended with method 'parakeet-tdt-v2' (the last record of an id wins).
    Needs ./python-nemo."""
    from .asr import load_model, transcribe
    from .corpora import Corpus
    from .util import load_audio

    p = ALIGN_DIR / f"{split}.jsonl"
    truncate_incomplete_tail(p)
    last = {r["id"]: r for r in read_jsonl(p)}
    todo = sorted(i for i, r in last.items() if r["method"] == "failed" or not r["words"])
    print(f"{split}: {len(todo)} utterances need the fallback", flush=True)
    if not todo:
        return
    c = Corpus(split)
    model = load_model()
    with open(p, "a") as f:
        for i in range(0, len(todo), 16):
            ids = todo[i : i + 16]
            hyps = transcribe(model, [load_audio(c.utterance_by_id[u].path) for u in ids], batch_size=8)
            for u, h in zip(ids, hyps):
                # An empty hypothesis for a non-empty transcript is not "no speech": it stays a failure.
                rec = {"id": u, "method": "parakeet-tdt-v2", "words": h["words"]} if h["words"] else {"id": u, "method": "failed", "error": "empty fallback", "words": []}
                f.write(json.dumps(rec) + "\n")


def main(argv: list[str] | None = None) -> None:
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    r = sub.add_parser("run")
    r.add_argument("--split", required=True)
    r.add_argument("--limit", type=int, default=None)
    fb = sub.add_parser("fallback")
    fb.add_argument("--split", required=True)
    sub.add_parser("coverage")
    a = ap.parse_args(argv)
    if a.cmd == "run":
        run(a.split, a.limit)
    elif a.cmd == "fallback":
        fallback(a.split)
    else:
        print(json.dumps(coverage(), indent=1))


if __name__ == "__main__":
    sys.exit(main())
