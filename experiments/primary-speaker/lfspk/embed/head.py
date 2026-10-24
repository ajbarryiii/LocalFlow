"""Stage B: fit the logistic heads of the frame scorer (DESIGN.md, Stage B).

  ./python[-nemo] -m lfspk.embed.head extract --embedder E --window 1.5 --hop 0.25 --n-mix 3000 [--device cuda]
  ./python -m lfspk.embed.head fit --embedder E --window 1.5 --hop 0.25 --norm asnorm --features score|all

`extract` draws training mixtures from W0's `MixtureSampler("train")`
restricted to fit-half speakers (`protocol.cohort_role == "fit"`), so no
speaker in the training data is in the AS-norm cohort. Mixture i comes with
n_i enrollment dictations of its target (n_i = 3 or 10, seeded; each
contaminated with probability 0.2, as in the contract's contaminated
condition). For the mixture and each enrollment dictation it stores the
scorer's window embeddings (`embed_windows`), plus the mixture's frame energy,
gate and labels. Nothing else; no audio is written.

`fit` builds each mixture's profile the way the harness does: enroll the
first 3 enrollment dictations, then update with the rest in order, using the
scorer's update rule and the gates calibrated on fit-half train speakers
(`adapt calibrate`, gates_<norm>.json). It then computes the frame features,
and fits sklearn's LogisticRegression (lbfgs, L2, C from --C) on all frames:
label 1 for frames 1 and 3 (target active), 0 for frames 0 and 2. The fitted
standardisation and coefficients become a `scorer.Head` (JSON). Choices of C,
feature set, window and hop are made later on dev half A, not here.
"""

from __future__ import annotations

import argparse
import json
import os
import tempfile
import time
from pathlib import Path

import numpy as np

from .. import paths
from . import protocol as P
from .survey import require_clean
from .scorer import UPDATE_WINDOW, FEATURES, Cohort, EmbeddingScorer, Head, ScorerConfig, UpdateConfig, WindowConfig, Windows, embed_windows

OUT = Path(os.environ.get("LFSPK_W1_HEAD_OUT", paths.RUNS / "W1" / "head"))  # override for smoke runs
ENROLL_SIZES = (3, 10)
CONTAMINATION = 0.2
BASE_SEED = 1


def _tag(embedder: str, window: float, hop: float) -> str:
    return f"{embedder}_L{window}_H{hop}"


def fit_speakers() -> list[str]:
    from .. import splits

    return [s.id for s in splits.speakers("train") if P.cohort_role(s.id) == "fit"]


def _pack(w: Windows) -> dict:
    return {"emb": w.emb.astype(np.float32), "spans": np.array(w.spans, np.int64).reshape(-1, 2),
            "n_layout": w.n_layout}


def cmd_extract(args) -> None:
    """Render each training mixture once and embed it for every requested
    (embedder, scoring window) pair; each pair gets its own generation
    directory (fresh, immutable) and its CURRENT is switched only after the
    whole run completed."""
    paths.require_mount()
    commit = require_clean(args.smoke)
    from ..harness.mix import MixtureSampler
    from ..harness.util import rng_for
    from .embedder import load_embedder

    if args.device.startswith("cuda"):
        import torch

        torch.cuda.set_per_process_memory_fraction(float(os.environ["AGENT_JOBS_VRAM_FRACTION"]))
    names = args.embedders or [args.embedder]
    windows = [tuple(float(x) for x in w.split(":")) for w in (args.windows or [f"{args.window}:{args.hop}"])]
    models = [load_embedder(n, args.device) for n in names]
    sampler = MixtureSampler("train", base_seed=BASE_SEED, speakers=fit_speakers())
    gens = {}
    for m in models:
        for L, H in windows:
            tag_dir = OUT / _tag(m.name, L, H)
            tag_dir.mkdir(parents=True, exist_ok=True)
            gens[(m.name, L, H)] = (tag_dir, Path(tempfile.mkdtemp(prefix=f"gen-{time.strftime('%Y%m%dT%H%M%S')}-",
                                                                   dir=tag_dir)))
    t0 = time.time()
    shards = {k: [] for k in gens}
    shard_no = 0
    index_hashes: dict = {}
    last = args.start + args.n_mix - 1
    for i in range(args.start, args.start + args.n_mix):
        n_enroll = ENROLL_SIZES[int(rng_for("w1-head-n", i).integers(len(ENROLL_SIZES)))]
        mix, enrol = sampler.with_enrollment(i, n_enroll, CONTAMINATION)
        h = mix.meta.get("index_hashes", {})
        if index_hashes and h != index_hashes:
            raise RuntimeError("W0 index/alignment hashes changed during extraction")
        index_hashes = h
        for m in models:
            enroll = [_pack(embed_windows(m, e.audio, UPDATE_WINDOW)) for e in enrol]
            for L, H in windows:
                w = embed_windows(m, mix.audio, WindowConfig(L, H))
                shards[(m.name, L, H)].append({
                    "i": i, "scenario": mix.meta["scenario"], "target": mix.meta["target"]["speaker"],
                    "mix": _pack(w), "energy_db": w.energy_db.astype(np.float32), "gate": w.gate,
                    "labels": mix.labels.astype(np.uint8), "enroll": enroll})
        if len(next(iter(shards.values()))) == 250 or i == last:
            for k, recs in shards.items():
                np.save(gens[k][1] / f"shard_{shard_no:04d}.npy", np.array(recs, dtype=object), allow_pickle=True)
            shards = {k: [] for k in gens}
            shard_no += 1
            print(f"{i + 1 - args.start}/{args.n_mix} mixtures, {time.time() - t0:.0f} s", flush=True)
    for m in models:
        for L, H in windows:
            tag_dir, d = gens[(m.name, L, H)]
            meta = {"embedder": m.name, "weights_sha256": m.weights_sha256, "window": WindowConfig(L, H).__dict__,
                    "update_window": UPDATE_WINDOW.__dict__, "base_seed": BASE_SEED, "enroll_sizes": ENROLL_SIZES,
                    "contamination": CONTAMINATION, "speakers": "fit half of train (protocol.cohort_role)",
                    "start": args.start, "n_mix": args.n_mix, "git": commit, "smoke": args.smoke,
                    "w0_index_hashes": index_hashes}
            (d / "meta.json").write_text(json.dumps(meta, indent=1))
            tmp = tag_dir / f".CURRENT.{os.getpid()}"
            tmp.write_text(d.name)
            os.replace(tmp, tag_dir / "CURRENT")
            print(json.dumps({"generation": str(d), "embedder": m.name, "window": [L, H]}))


def _unpack(r: dict) -> Windows:
    return Windows([tuple(x) for x in r["spans"].tolist()], r["emb"], np.zeros(0), np.zeros(0, bool), r["n_layout"])


def load_records(d: Path) -> list[dict]:
    out = []
    for f in sorted(d.glob("shard_*.npy")):
        out.extend(np.load(f, allow_pickle=True).tolist())  # our own files, written by cmd_extract
    return out


def current_generation(tag_dir: Path) -> Path:
    """The generation directory CURRENT points to (written last by a complete extraction)."""
    cur = tag_dir / "CURRENT"
    if not cur.is_file():
        raise FileNotFoundError(f"{tag_dir}: no complete extraction (CURRENT missing)")
    d = tag_dir / cur.read_text().strip()
    if not d.is_dir() or not d.name.startswith("gen-"):
        raise RuntimeError(f"{cur} points to {d}, not a generation directory")
    return d


def check_extraction_provenance(d: Path, smoke: bool) -> None:
    """A generation directory must hold meta.json, its shards must hold
    exactly the declared n_mix mixtures, and, for a real fit, the extraction
    must have been a real committed run."""
    from .adapt import check_upstream

    m = d / "meta.json"
    if not m.is_file():
        raise RuntimeError(f"{d}: no metadata (interrupted extraction?)")
    meta = json.loads(m.read_text())
    n = sum(len(np.load(f, allow_pickle=True)) for f in sorted(d.glob("shard_*.npy")))
    if n != meta.get("n_mix"):
        raise RuntimeError(f"{m}: {n} mixtures in shards, metadata says {meta.get('n_mix')}")
    check_upstream({"git": meta.get("git", "unknown"), "smoke": meta.get("smoke", True)}, smoke, str(m))


def features_for(scorer: EmbeddingScorer, rec: dict) -> tuple[dict, np.ndarray]:
    """Frame features of one stored mixture, and its labels. The profile is
    built as in the harness: enroll(first 3) then update with the rest."""
    wins = [_unpack(e) for e in rec["enroll"]]
    prof = scorer.enroll_windows(wins[:3])
    for w in wins[3:]:
        prof = scorer.update_windows(prof, w)
    w = _unpack(rec["mix"])
    w.energy_db, w.gate = rec["energy_db"], rec["gate"]
    n = rec["labels"].size
    audio_stub = np.zeros(n * 160, np.float32)  # frame_features needs only the length when windows are given
    return scorer.frame_features(prof, audio_stub, windows=w), rec["labels"]


def make_scorer(embedder: str, window: float, hop: float, norm: str, rule: str = "robust",
                gates: dict | None = None, cohort_root: Path | None = None) -> EmbeddingScorer:
    """A scorer for features from stored windows (no model is loaded)."""
    upd = UpdateConfig(rule=rule)
    if gates and rule != "naive":
        upd = UpdateConfig(rule=rule, window_gate=gates["window_gate"], dictation_gate=gates["dictation_gate"],
                           anchor_gate=gates.get("anchor_gate", -1.0), drift_floor=gates.get("drift_floor", -1.0))
    cfg = ScorerConfig(embedder, WindowConfig(window, hop), norm=norm, update=upd)

    class _NoModel:  # features come from stored windows; no audio is embedded
        name = embedder
        dim = 0
        params = 0

    cohort = (Cohort.from_survey(embedder, window, cohort_root, update_s=UPDATE_WINDOW.window_s)
              if norm == "asnorm" else None)
    return EmbeddingScorer(cfg, embedder=_NoModel(), cohort=cohort)  # type: ignore[arg-type]


def fit_head(X: np.ndarray, y: np.ndarray, names: tuple[str, ...], C: float) -> Head:
    from sklearn.linear_model import LogisticRegression

    mean = X.mean(axis=0)
    scale = X.std(axis=0)
    scale[scale < 1e-8] = 1.0
    lr = LogisticRegression(C=C, max_iter=2000)
    lr.fit((X - mean) / scale, y)
    return Head(tuple(names), tuple(map(float, mean)), tuple(map(float, scale)), tuple(map(float, lr.coef_[0])),
                float(lr.intercept_[0]))


def cmd_fit(args) -> None:
    commit = require_clean(args.smoke)
    tag_dir = OUT / _tag(args.embedder, args.window, args.hop)
    d = current_generation(tag_dir)
    check_extraction_provenance(d, args.smoke)
    recs = load_records(d)
    from .adapt import load_gates

    gates = load_gates(args.embedder, args.norm, args.smoke) if args.rule != "naive" else None  # update windows
    sc = make_scorer(args.embedder, args.window, args.hop, args.norm, args.rule, gates)
    names = ("score",) if args.features == "score" else FEATURES
    Xs, ys = [], []
    for r in recs:
        f, lab = features_for(sc, r)
        Xs.append(np.stack([f[k] for k in names], axis=1))
        ys.append(((lab == 1) | (lab == 3)).astype(np.int64))
    X, y = np.concatenate(Xs), np.concatenate(ys)
    head = fit_head(X, y, names, args.C)
    out = tag_dir / f"head_{args.norm}_{args.rule}_{args.features}_C{args.C}.json"
    out.write_text(head.to_json())
    info = {"head": str(out), "frames": int(y.size), "positive_rate": float(y.mean()), "mixtures": len(recs),
            "git": commit, "smoke": args.smoke, "generation": d.name, "rule": args.rule, "norm": args.norm,
            "features": args.features,
            "C": args.C}
    out.with_suffix(".meta.json").write_text(json.dumps(info, indent=1))
    print(json.dumps(info))


def main(argv=None) -> None:
    ap = argparse.ArgumentParser(prog="lfspk.embed.head")
    sub = ap.add_subparsers(dest="cmd", required=True)
    e = sub.add_parser("extract")
    e.add_argument("--embedder", default=None)
    e.add_argument("--embedders", nargs="+", default=None, help="several embedders in one rendering pass")
    e.add_argument("--window", type=float, default=1.5)
    e.add_argument("--hop", type=float, default=0.25)
    e.add_argument("--windows", nargs="+", default=None, help="L:H scoring windows, e.g. 1.0:0.25 1.5:0.5")
    e.add_argument("--n-mix", type=int, default=3000)
    e.add_argument("--start", type=int, default=0)
    e.add_argument("--device", default="cpu")
    f = sub.add_parser("fit")
    f.add_argument("--embedder", required=True)
    f.add_argument("--window", type=float, default=1.5)
    f.add_argument("--hop", type=float, default=0.25)
    f.add_argument("--norm", choices=("raw", "asnorm"), default="asnorm")
    f.add_argument("--features", choices=("score", "all"), default="all")
    f.add_argument("--C", type=float, default=1.0)
    for p in (e, f):
        p.add_argument("--smoke", action="store_true", help="allow uncommitted code (not a result)")
    f.add_argument("--rule", choices=("naive", "gated", "robust", "anchored"), default="robust")
    args = ap.parse_args(argv)
    {"extract": cmd_extract, "fit": cmd_fit}[args.cmd](args)


if __name__ == "__main__":
    main()
