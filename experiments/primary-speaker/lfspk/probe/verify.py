"""Stage 2b scoring (CPU job): fit the back end on train, score every dev trial.

    ./python -m lfspk.probe.verify --system base

Writes RUNS/W2/verify/<system>[-lda<k>]/scores.npz with, per tap and length,
the [models, tests] cosine matrix, plus trial metadata (model speaker,
test speaker, sexes, same-chapter flags), and backends.npz with the fitted
back end of every tap (stage 3 reuses them). Metrics come from report.py.
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path

import numpy as np

from lfspk import paths

from .backend import LDA_DIM, Backend, cosine_matrix, enrollment_model, l2norm
from .select import LENGTHS, dev_halves, dev_strata

FEATS = paths.RUNS / "W2" / "feats"
OUT = paths.RUNS / "W2" / "verify"


def load_feats(feature: str, split: str, root: Path = FEATS):
    d = root / feature / split
    meta = json.loads((d / "meta.json").read_text())
    if meta.get("limit"):
        from .guard import require_scratch

        require_scratch(d, f"smoke feature set {d} (limit={meta['limit']})")
    check_invariance(meta, d)
    arr = np.load(d / "features.npy", mmap_mode="r")
    index = json.loads((d / "index.json").read_text())
    selection = json.loads((d / "selection.json").read_text())
    return arr, index, selection, meta


def check_invariance(meta: dict, where) -> None:
    """Refuse features whose batch-vs-single check exceeded the tolerance (DESIGN 5.2)."""
    from .extract import INVARIANCE_TOL

    inv = meta.get("batch_invariance_max_rel")
    if not inv:
        raise ValueError(f"{where}: no batching-invariance record")
    bad = {k: v for k, v in inv.items() if not v <= INVARIANCE_TOL}
    if bad:
        raise ValueError(f"{where}: batching invariance {bad} exceeds {INVARIANCE_TOL}")


def row_lookup(index: list[dict]) -> dict[tuple[str, str], int]:
    return {(it["utt"], it["length"]): i for i, it in enumerate(index)}


def dev_trials(index: list[dict], selection: dict):
    """Enrollment model rows and test rows per length, with metadata."""
    rows = row_lookup(index)
    plans = selection["plans"]
    sex = selection["sex"]
    models = []  # (speaker, [rows])
    for p in plans:
        for utts in p["enroll_models"]:
            models.append((p["speaker"], [rows[(u, "full")] for u in utts]))
    tests = {length: [] for length in LENGTHS}
    for p in plans:
        for u in p["test"]:
            for length in LENGTHS:
                tests[length].append((p["speaker"], u, rows[(u, length)]))
    session = {p["speaker"]: p["session"] for p in plans}
    return models, tests, sex, session


def score_system(feature: str, taps: list[int] | None, lda_dim: int, raw_cosine: bool, out: Path,
                 feats_root: Path = FEATS, dev_feature: str | None = None, smoke: bool = False) -> None:
    """Back end fitted on `feature`'s train features; dev trials scored on
    `dev_feature` (default the same; e.g. "base-colour" for the channel control)."""
    from .guard import check_inputs

    tr, tr_index, _, tr_meta = load_feats(feature, "train", feats_root)
    dv, dv_index, dv_sel, dv_meta = load_feats(dev_feature or feature, "dev", feats_root)
    check_inputs([tr_meta, dv_meta], smoke, out, "verify")
    models, tests, sex, session = dev_trials(dv_index, dv_sel)
    y = np.array([it["speaker"] for it in tr_index])
    taps = list(range(tr.shape[0])) if taps is None else taps
    model_rows = [r for _, rs in models for r in rs]
    result: dict[str, np.ndarray] = {}
    backends: dict[str, np.ndarray] = {}
    for tap in taps:
        if raw_cosine:
            transform = l2norm
        else:
            be = Backend.fit(np.asarray(tr[tap], dtype=np.float64), y, lda_dim)
            transform = be.transform
            for k, v in be.to_npz().items():
                backends[f"tap{tap}/{k}"] = v
        enr = transform(np.asarray(dv[tap][model_rows], dtype=np.float64))
        m_emb, pos = [], 0
        for _, rs in models:
            m_emb.append(enrollment_model(enr[pos:pos + len(rs)]))
            pos += len(rs)
        m_emb = np.stack(m_emb)
        for length, ts in tests.items():
            t_emb = transform(np.asarray(dv[tap][[r for _, _, r in ts]], dtype=np.float64))
            result[f"tap{tap}/{length}"] = cosine_matrix(m_emb, t_emb).astype(np.float32)
        print(f"{feature} tap {tap} scored", flush=True)
    out.mkdir(parents=True, exist_ok=True)
    meta = {
        "model_speaker": np.array([s for s, _ in models]),
        "test_speaker": np.array([s for s, _, _ in tests["full"]]),
        "test_utt": np.array([u for _, u, _ in tests["full"]]),
        "speakers": np.array(sorted(sex, key=int)),
        "sex": np.array([sex[s] for s in sorted(sex, key=int)]),
        "session": np.array([session[s] for s in sorted(sex, key=int)]),
        "half_S": np.array(dev_halves(dev_strata(dv_sel["plans"], sex, dv_sel["subset"]))[0]),
        "half_E": np.array(dev_halves(dev_strata(dv_sel["plans"], sex, dv_sel["subset"]))[1]),
        "taps": np.array(taps),
    }
    np.savez(out / "scores.npz", **result, **{f"meta/{k}": v for k, v in meta.items()})
    if backends:
        np.savez(out / "backends.npz", **backends)
    (out / "run.json").write_text(json.dumps({"feature": feature, "dev_feature": dev_feature or feature,
                                              "lda_dim": lda_dim, "raw_cosine": raw_cosine, "taps": taps}))


def main(argv=None) -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--feature", required=True, help="base, m1, logmel, titanet")
    ap.add_argument("--taps", type=int, nargs="*")
    ap.add_argument("--lda-dim", type=int, default=LDA_DIM)
    ap.add_argument("--raw-cosine", action="store_true", help="no back end (TitaNet's intended use)")
    ap.add_argument("--colour", action="store_true", help="score coloured dev test segments (channel control)")
    ap.add_argument("--smoke", action="store_true", help="allow smoke feature sets (scratch outputs only)")
    args = ap.parse_args(argv)
    paths.require_mount()
    name = (args.feature + ("-colour" if args.colour else "") + ("-raw" if args.raw_cosine else "")
            + ("" if args.lda_dim == LDA_DIM else f"-lda{args.lda_dim}"))
    score_system(args.feature, args.taps, args.lda_dim, args.raw_cosine, OUT / name,
                 dev_feature=args.feature + "-colour" if args.colour else None, smoke=args.smoke)


if __name__ == "__main__":
    main()
