"""Stage 2 feature extraction (GPU job). Writes pooled features per item.

    ./python-nemo -m lfspk.probe.extract --system base --split dev

Systems: base / m1 (25 taps x 2048, plus `logmel` 1 x 256 from the base pass),
titanet (1 x 192). Items are (utterance, length condition) rows; see
`items_for_split`. Output under RUNS/W2/feats/<system>/<split>/:
features.npy (float16 [taps, N, dim], tap-major), index.json, meta.json (written last;
its presence marks a complete extraction).
"""

from __future__ import annotations

import argparse
import json
import os
import queue
import subprocess
import threading
import time
from dataclasses import asdict, dataclass
from pathlib import Path

import numpy as np

from lfspk import paths, splits

from . import N_TAPS
from .select import LENGTHS, choose_crop, crop_key, dev_plan, load_projects, rng_for, train_selection

OUT = paths.RUNS / "W2" / "feats"
BATCH_SECONDS = 480.0
MAX_BATCH = 64
INVARIANCE_TOL = 1e-3  # max relative batch-vs-single difference of pooled features (DESIGN 5.2)


@dataclass(frozen=True)
class Item:
    utt: str
    speaker: str
    length: str  # key of LENGTHS
    path: str
    role: str = "train"  # train | enroll | test


def utterance_map(split: str) -> tuple[dict[str, list[str]], dict[str, str], dict[str, str]]:
    """speaker -> utterance ids, utterance id -> path, speaker -> sex."""
    by_spk, where, sex = {}, {}, {}
    for spk in splits.speakers(split):
        files = splits.utterances(spk)
        by_spk[spk.id] = [f.stem for f in files]
        where.update({f.stem: str(f) for f in files})
        sex[spk.id] = spk.sex
    return by_spk, where, sex


def items_for_split(split: str, max_speakers: int = 0) -> tuple[list[Item], dict]:
    """Items of a split; max_speakers > 0 keeps only the first speakers (smoke runs)."""
    if split == "test":
        raise PermissionError("the test split is sealed")
    by_spk, where, sex = utterance_map(split)
    if max_speakers:
        keep = sorted(by_spk, key=int)[:max_speakers]
        by_spk = {k: by_spk[k] for k in keep}
        sex = {k: sex[k] for k in keep}
    items: list[Item] = []
    if split == "train":
        sel = train_selection(by_spk)
        for spk, utts in sel.items():
            for u in utts:
                for length in LENGTHS:
                    items.append(Item(u, spk, length, where[u]))
        manifest = {"split": split, "selection": sel, "sex": sex}
    else:
        plans = dev_plan(by_spk, load_projects())
        for p in plans:
            for model in p.enroll_models:
                for u in model:
                    items.append(Item(u, p.speaker, "full", where[u], "enroll"))
            for u in p.test:
                for length in LENGTHS:
                    items.append(Item(u, p.speaker, length, where[u], "test"))
        subset = {spk.id: spk.subset for spk in splits.speakers(split) if spk.id in by_spk}
        manifest = {"split": split, "plans": [asdict(p) for p in plans], "sex": sex, "subset": subset}
    items.sort(key=lambda it: (it.utt, list(LENGTHS).index(it.length)))
    return items, manifest


def load_item(item: Item, coloured: bool = False) -> tuple[np.ndarray, dict]:
    """Audio of an item (cropped for 1 s / 2 s). With `coloured`, test items get
    the W2-colour-v1 device colouring after cropping (the crop is chosen on the
    clean audio, so clean and coloured runs use identical windows)."""
    import soundfile as sf

    from .colour import colour

    audio, sr = sf.read(item.path, dtype="float32")
    if sr != 16000 or audio.ndim != 1:
        raise ValueError(f"{item.path}: unexpected format")
    seconds = LENGTHS[item.length]
    if seconds is None:
        out, info = audio, {"start": 0, "samples": int(audio.size), "active_fraction": None, "fallback": False}
    else:
        crop = choose_crop(audio, seconds, rng_for(*crop_key(item.utt, item.length)))
        out, info = audio[crop.start:crop.start + crop.length], {
            "start": crop.start, "samples": crop.length, "active_fraction": crop.active_fraction,
            "fallback": crop.fallback}
    if coloured and item.role == "test":
        out = colour(out)
    return out, {**info, "coloured": bool(coloured and item.role == "test")}


def batches(items: list[Item]) -> list[list[int]]:
    import soundfile as sf

    sizes = []
    for it in items:
        n = sf.info(it.path).frames
        s = LENGTHS[it.length]
        sizes.append(n if s is None else min(n, int(s * 16000)))
    order = np.argsort(sizes, kind="stable")
    out, cur, cur_max = [], [], 0
    for i in order:
        new_max = max(cur_max, sizes[i])
        if cur and (new_max * (len(cur) + 1) > BATCH_SECONDS * 16000 or len(cur) >= MAX_BATCH):
            out.append(cur)
            cur, new_max = [], sizes[i]
        cur.append(int(i))
        cur_max = new_max
    if cur:
        out.append(cur)
    return out


class _Failed:
    def __init__(self, exc: BaseException):
        self.exc = exc


def prefetch(items, plan, workers=6, load=load_item):
    """Yields (batch indices, list of audio arrays, crop infos) in plan order.
    A loading error in the producer is re-raised in the consumer."""
    from concurrent.futures import ThreadPoolExecutor

    q: queue.Queue = queue.Queue(maxsize=4)

    def run():
        try:
            with ThreadPoolExecutor(workers) as ex:
                for idx in plan:
                    loaded = list(ex.map(lambda i: load(items[i]), idx))
                    q.put((idx, [a for a, _ in loaded], [c for _, c in loaded]))
            q.put(None)
        except BaseException as e:  # noqa: BLE001 - forwarded to the consumer
            q.put(_Failed(e))
    threading.Thread(target=run, daemon=True).start()
    while (got := q.get()) is not None:
        if isinstance(got, _Failed):
            raise RuntimeError("audio loading failed") from got.exc
        yield got


def to_batch(audios, device):
    import torch

    n = max(a.size for a in audios)
    x = np.zeros((len(audios), n), dtype=np.float32)
    for i, a in enumerate(audios):
        x[i, : a.size] = a
    return torch.from_numpy(x).to(device), torch.tensor([a.size for a in audios], device=device)


def invariance_rel(single: np.ndarray, batched: np.ndarray) -> float:
    """Max |single - batched| relative to max |single|; raises if either side
    or the result is not finite (a NaN must never pass as 'no difference')."""
    if not (np.isfinite(single).all() and np.isfinite(batched).all()):
        raise RuntimeError("non-finite features in the batching-invariance check")
    rel = float(np.abs(single - batched).max() / max(np.abs(single).max(), 1e-12))
    if not np.isfinite(rel):
        raise RuntimeError("non-finite batching-invariance difference")
    return rel


def check_output(out: Path, smoke: bool) -> None:
    """Smoke extractions (--limit, --max-speakers) never write into W2's
    production artifacts, however the path is spelled."""
    if smoke:
        from .guard import require_scratch

        require_scratch(out, "smoke extraction output")


def git_commit() -> str:
    here = Path(__file__).resolve().parents[2]
    r = subprocess.run(["git", "-C", str(here), "rev-parse", "HEAD"], capture_output=True, text=True)
    d = subprocess.run(["git", "-C", str(here), "status", "--porcelain", "--", "lfspk/probe"], capture_output=True, text=True)
    return r.stdout.strip() + ("-dirty" if d.stdout.strip() else "")


def main(argv=None) -> None:
    import torch

    ap = argparse.ArgumentParser()
    ap.add_argument("--system", choices=["base", "m1", "titanet"], required=True)
    ap.add_argument("--split", choices=["train", "dev"], required=True)
    ap.add_argument("--limit", type=int, default=0, help="smoke runs: first N items only")
    ap.add_argument("--colour", action="store_true", help="dev only: colour test items (W2-colour-v1)")
    ap.add_argument("--max-speakers", type=int, default=0, help="smoke runs: first N speakers only")
    ap.add_argument("--out", type=Path, default=OUT)
    args = ap.parse_args(argv)
    paths.require_mount()
    if "AGENT_JOBS_VRAM_FRACTION" in os.environ:
        torch.cuda.set_per_process_memory_fraction(float(os.environ["AGENT_JOBS_VRAM_FRACTION"]))
    device = "cuda"

    if args.colour and args.split != "dev":
        raise ValueError("--colour applies to dev test items only")
    suffix = "-colour" if args.colour else ""
    check_output(args.out, smoke=bool(args.limit or args.max_speakers))
    items, manifest = items_for_split(args.split, args.max_speakers)
    if args.limit:
        items = items[: args.limit]
    plan = batches(items)
    outputs = {}
    if args.system == "titanet":
        from .models import load_titanet, titanet_embed

        model = load_titanet(device)
        embed = lambda x, l: {"titanet": titanet_embed(model, x, l)[:, None, :]}  # noqa: E731
        dims = {"titanet": (1, 192)}
    else:
        from .models import TapEncoder, load_parakeet
        from .pooling import mean_std

        tap = TapEncoder(load_parakeet(args.system, device))

        def embed(x, l):
            res = {args.system: tap.pooled(x, l)}
            if args.system == "base":
                lm, ll = tap.raw_logmel(x, l)
                res["logmel"] = mean_std(lm, ll)[:, None, :]
            return res
        dims = {args.system: (N_TAPS, 2048)}
        if args.system == "base":
            dims["logmel"] = (1, 256)

    dims = {name + suffix: v for name, v in dims.items()}
    inner = embed
    embed = lambda x, l: {k + suffix: v for k, v in inner(x, l).items()}  # noqa: E731
    for name, (taps, dim) in dims.items():
        d = args.out / name / args.split
        d.mkdir(parents=True, exist_ok=True)
        (d / "meta.json").unlink(missing_ok=True)
        (d / "index.json").write_text(json.dumps([asdict(it) for it in items]))
        (d / "selection.json").write_text(json.dumps(manifest))
        outputs[name] = (d, np.lib.format.open_memmap(d / "features.npy", mode="w+", dtype=np.float16,
                                                      shape=(taps, len(items), dim)))
    crops: list[dict | None] = [None] * len(items)
    invariance = None
    t0 = time.time()
    done = 0
    from functools import partial

    for bi, (idx, audios, infos) in enumerate(prefetch(items, plan, load=partial(load_item, coloured=args.colour))):
        x, l = to_batch(audios, device)
        res = embed(x, l)
        for name, arr in res.items():
            a = arr.float().cpu().numpy()
            if not np.isfinite(a).all():
                raise RuntimeError(f"non-finite features in batch {bi}")
            outputs[name][1][:, idx] = a.astype(np.float16).transpose(1, 0, 2)
        for i, c in zip(idx, infos):
            crops[i] = c
        if len(idx) > 1 and bi in (0, len(plan) // 2, len(plan) - 1):
            # Padding/batching invariance on the first, middle and last batch:
            # re-run the batch's first 2 and last 2 items alone.
            worst = dict(invariance or {})
            for j in sorted({0, 1, len(idx) - 2, len(idx) - 1}):
                xs, ls = to_batch([audios[j]], device)
                single = embed(xs, ls)
                for name, arr in single.items():
                    rel = invariance_rel(arr.double().cpu().numpy()[0], res[name].double().cpu().numpy()[j])
                    worst[name] = max(worst.get(name, 0.0), rel)
            invariance = worst
            print("batch invariance (max rel diff)", invariance, flush=True)
        done += len(idx)
        if bi % 20 == 0:
            print(f"{done}/{len(items)} items, {time.time() - t0:.0f}s", flush=True)
    if invariance is None:
        raise RuntimeError("batching invariance was never checked")
    bad = {k: v for k, v in invariance.items() if not v <= INVARIANCE_TOL}
    if bad:
        raise RuntimeError(f"batching invariance {bad} exceeds {INVARIANCE_TOL}; features rejected")
    meta_common = {
        "system": args.system, "colour": "W2-colour-v1 on test items" if args.colour else None,
        "split": args.split, "items": len(items),
        "limit": args.limit or (f"speakers={args.max_speakers}" if args.max_speakers else 0),
        "commit": git_commit(), "seconds": time.time() - t0, "batch_invariance_max_rel": invariance,
        "crop_fallbacks": sum(1 for c in crops if c and c["fallback"]),
        "torch": torch.__version__, "tf32": torch.backends.cuda.matmul.allow_tf32,
    }
    for name, (d, arr) in outputs.items():
        arr.flush()
        (d / "crops.json").write_text(json.dumps(crops))
        (d / "meta.json").write_text(json.dumps({**meta_common, "feature": name, "shape": list(arr.shape)}, indent=1))
    print("done", json.dumps(meta_common), flush=True)


if __name__ == "__main__":
    main()
