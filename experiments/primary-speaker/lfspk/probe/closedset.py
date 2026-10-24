"""Stage 2a (CPU job): closed-set speaker identification with a linear probe.

    ./python -m lfspk.probe.closedset --features base m1 logmel titanet

200 train-split speakers with two chapters among their selected utterances;
fit on chapter A, test on chapter B (cross-session). Writes
RUNS/W2/closedset/report.json.
"""

from __future__ import annotations

import argparse
import json
import os
from concurrent.futures import ProcessPoolExecutor

import numpy as np

from lfspk import paths

from . import SEED
from .metrics import bootstrap, one_way, resample_weights
from .select import chapter_of, load_projects, rng_for
from .verify import load_feats, row_lookup

OUT = paths.RUNS / "W2" / "closedset"
N_SPEAKERS = 200
C_GRID = (0.01, 0.1, 1.0)
LENGTHS = ("full", "2s")


def choose_split(selection: dict[str, list[str]], project_of: dict[str, str]) -> dict[str, tuple[list[str], list[str], bool]]:
    """speaker -> (chapter-A utterances, chapter-B utterances, cross_project) for
    N_SPEAKERS seeded speakers with at least two selected chapters and >= 3
    utterances in A. The pair (A, B) is the first pair of selected chapters, in
    sorted order, from different LibriVox projects; if none, the first two."""
    eligible = []
    for spk in sorted(selection, key=int):
        chaps = sorted({chapter_of(u) for u in selection[spk]}, key=int)
        pairs = [(a, b) for i, a in enumerate(chaps) for b in chaps[i + 1:]]
        cross = [(a, b) for a, b in pairs if project_of[a] != project_of[b]]
        for ca, cb in (cross + pairs)[:1]:
            a = sorted(u for u in selection[spk] if chapter_of(u) == ca)
            b = sorted(u for u in selection[spk] if chapter_of(u) == cb)
            if len(a) >= 3 and b:
                eligible.append((spk, a, b, project_of[ca] != project_of[cb]))
    if len(eligible) < N_SPEAKERS:
        raise ValueError(f"only {len(eligible)} eligible speakers")
    idx = sorted(rng_for("closedset").choice(len(eligible), N_SPEAKERS, replace=False))
    return {eligible[i][0]: eligible[i][1:] for i in idx}


def fit_probe(xa: np.ndarray, ya: np.ndarray, seed: int = SEED):
    """Standardise, pick C by stratified 3-fold CV on the training data, refit."""
    from sklearn.linear_model import LogisticRegression
    from sklearn.model_selection import StratifiedKFold
    from sklearn.pipeline import make_pipeline
    from sklearn.preprocessing import StandardScaler

    def make(c):
        return make_pipeline(StandardScaler(), LogisticRegression(C=c, max_iter=3000, tol=1e-4))

    cv_acc = {}
    for c in C_GRID:
        accs = []
        for tr, va in StratifiedKFold(3, shuffle=True, random_state=seed).split(xa, ya):
            accs.append(make(c).fit(xa[tr], ya[tr]).score(xa[va], ya[va]))
        cv_acc[c] = float(np.mean(accs))
    best = max(C_GRID, key=lambda c: (cv_acc[c], -c))
    return make(best).fit(xa, ya), best, cv_acc


def _rows(feature: str, length: str):
    _, index, sel, _ = load_feats(feature, "train")
    split = choose_split(sel["selection"], load_projects())
    rows = row_lookup(index)
    spk_idx = {s: i for i, s in enumerate(split)}
    ra = [(rows[(u, length)], s) for s, (a, _, _) in split.items() for u in a]
    rb = [(rows[(u, length)], s) for s, (_, b, _) in split.items() for u in b]
    cross = np.array([split[s][2] for s in split])
    return ([r for r, _ in ra], np.array([spk_idx[s] for _, s in ra]),
            [r for r, _ in rb], np.array([spk_idx[s] for _, s in rb]), cross)


def subset_accuracies(correct: np.ndarray, yb: np.ndarray, cross: np.ndarray, n_boot: int = 1000) -> dict:
    """Accuracy with speaker-bootstrap CIs on all test items, cross-project and
    same-project speakers (resampling stratified by that flag); an empty subset
    is reported as NaN."""
    n = cross.size
    mult = resample_weights(n, n_boot, SEED, strata=cross.astype(int))  # keeps subset sizes fixed
    out = {}
    for name, keep in (("accuracy", np.ones(n, bool)), ("accuracy_cross_project", cross),
                       ("accuracy_same_project", ~cross)):
        items = keep[yb]
        if not items.any():
            out[name] = {"value": float("nan"), "lo": float("nan"), "hi": float("nan")}
            continue
        corr, groups = correct[items], yb[items]

        def acc(w, corr=corr):
            w = np.ones_like(corr) if w is None else w
            if w.sum() <= 0:
                raise ValueError("empty resample")
            return float((w * corr).sum() / w.sum())
        out[name] = bootstrap(acc, one_way(groups), mult).as_dict()
    return out


def _task(args):
    feature, tap, length = args
    arr = load_feats(feature, "train")[0]
    ra, ya, rb, yb, cross = _rows(feature, length)
    xa = np.asarray(arr[tap][ra], dtype=np.float64)
    xb = np.asarray(arr[tap][rb], dtype=np.float64)
    model, c, cv = fit_probe(xa, ya)
    correct = (model.predict(xb) == yb).astype(np.float64)
    res = {"C": c, "cv_accuracy": cv, "train_items": int(len(ya)), "test_items": int(len(yb)),
           "cross_project_speakers": int(cross.sum()), **subset_accuracies(correct, yb, cross)}
    return feature, tap, length, res


def main(argv=None) -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--features", nargs="+", default=["base", "m1", "logmel", "titanet"])
    ap.add_argument("--taps", type=int, nargs="*", help="smoke runs only")
    ap.add_argument("--workers", type=int, default=8)
    ap.add_argument("--smoke", action="store_true", help="allow smoke feature sets (scratch outputs only)")
    args = ap.parse_args(argv)
    paths.require_mount()
    from .guard import check_inputs

    check_inputs([load_feats(f, "train")[3] for f in args.features], args.smoke, OUT, "closedset")
    if os.environ.get("OMP_NUM_THREADS") != "1":
        print("note: OMP_NUM_THREADS is not 1; workers may oversubscribe", flush=True)
    out: dict = {}
    tasks = []
    for feature in args.features:
        n_taps = load_feats(feature, "train")[0].shape[0]
        for length in LENGTHS:
            for tap in range(n_taps):
                if args.taps is None or tap in args.taps or n_taps == 1:
                    tasks.append((feature, tap, length))
    with ProcessPoolExecutor(args.workers) as ex:
        for feature, tap, length, res in ex.map(_task, tasks):
            out.setdefault(feature, {}).setdefault(f"tap{tap}", {})[length] = res
            print(feature, tap, length, res["accuracy"], "C", res["C"], flush=True)
    OUT.mkdir(parents=True, exist_ok=True)
    name = "report.json" if args.taps is None else "report-partial.json"
    (OUT / name).write_text(json.dumps({"speakers": N_SPEAKERS, "results": out}, indent=1))


if __name__ == "__main__":
    main()
