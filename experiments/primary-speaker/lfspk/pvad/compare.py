"""Paired word-level comparisons and the pre-registered selection rule
(DESIGN.md sections 3 and 7), on scores saved by W0's evaluator.

    ./python -m lfspk.pvad.compare pair --set <dev set> --half A --a DIR_A --b DIR_B [--cond builtin,clean,10]
    ./python -m lfspk.pvad.compare select --set <dev set> --half A --candidates DIR_S DIR_Mc DIR_Mf DIR_Mfc DIR_L

A paired comparison reuses W0's own word ledger (lfspk.harness.metrics.Ledger)
and joint speaker resampling: in each of the 2000 resamples both systems get
the same mixture weights, each recalibrates its own tau to the 0.5 % budget,
and the statistic is the difference of their metric. The headline mixture mask
is W0's (enrollment relation cross_project or same_project_cross_chapter at
k, coherent RIRs, mixtures that reached k).
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Callable, Sequence

import numpy as np

MARGIN = 0.02  # non-inferiority margin in interferer words kept (DESIGN.md section 7)
SELECTION_METRIC = ("pooled_S1-S4", "interferer_kept/all")
G_LIMIT = 0.001  # S0 WER increase over the oracle's below 0.1 points (oracle-relative G, contract e4782a5)


# The five selection candidates in the fixed total order (smallest first), as
# (size, conditioning, enroll_policy) of the training run. A1 and A5 are not candidates.
CANDIDATE_ORDER = (("S", "film_cos", "robust"), ("M", "concat", "robust"), ("M", "film", "robust"),
                   ("M", "film_cos", "robust"), ("L", "film_cos", "robust"))


def load_scores_strict(out: Path, speakers: Sequence[str]) -> dict[str, np.ndarray]:
    """Saved frame scores; refuses anything but float32 (float16 storage ties
    confident scores near 1, review eval-r1)."""
    allsc: dict[str, np.ndarray] = {}
    for spk in speakers:
        with np.load(Path(out) / "scores" / f"{spk}.npz", allow_pickle=False) as z:
            for k in z.files:
                if z[k].dtype != np.float32:
                    raise ValueError(f"{out}: scores for {spk} are {z[k].dtype}, not float32; rescore with the "
                                     "float32 evaluator")
                allsc[k] = z[k]
    return allsc


def check_provenance(result_dir: Path, set_id: str, set_hash: str) -> None:
    """The evaluation must be of the requested frozen set: mixture ids repeat
    across sets, so equal coverage alone does not prove the same audio."""
    path = Path(result_dir) / "results.json"
    if not path.exists():
        raise ValueError(f"{result_dir}: no results.json, so its frozen set is unknown")
    res = json.loads(path.read_text())
    if res.get("set_id") != set_id or res.get("set_hash") != set_hash:
        raise ValueError(f"{result_dir}: scores are of set {res.get('set_id')} ({res.get('set_hash')}), "
                         f"not {set_id} ({set_hash})")


def _setup(set_id: str, half: str, cond: tuple[str, bool, int], dirs: Sequence[Path], fs=None, words=None,
           with_oracle: bool = False):
    """Shared population and one W0 Ledger per system, in `dirs` order;
    with_oracle appends the oracle's ledger (W0's oracle_scores: 1 on
    target-active frames) on the same rows."""
    from lfspk.harness import evaluate as EV
    from lfspk.harness import metrics as M
    from lfspk.harness.frozen import FrozenSet
    from lfspk.harness.refs import read_words

    fs = fs or FrozenSet(set_id)
    words = words if words is not None else read_words(set_id)
    rows = [r for r in fs.manifest if half == "all" or r["half"] == half]
    speakers = sorted({r["speaker"] for r in rows}, key=int)
    universe = sorted({s for r in rows for s in EV.involved_speakers(r)}, key=int)
    tok = M.build_tokens([words[r["id"]] for r in rows], [r["scenario"] for r in rows])
    inv = M.involvement_matrix([EV.involved_speakers(r) for r in rows], universe)
    scen = np.array([M.SCENARIOS.index(r["scenario"]) for r in rows])
    device, contaminated, k = cond
    key = EV.cond_key(device, contaminated, k)
    rel = np.array([r["relation_at"][str(k)] or "short" for r in rows])
    primary = np.array([r.get("rir_mode", "coherent") == "coherent" for r in rows])
    ledgers, haves = [], []
    for d in dirs:
        check_provenance(Path(d), set_id, fs.hash)
        sc = load_scores_strict(Path(d), speakers)
        expected = EV.expected_score_keys(fs, rows)  # W0's coverage rule: no missing or foreign keys
        if sorted(sc) != expected:
            raise ValueError(f"{d}: {len(sc)} score keys, expected {len(expected)}; incomplete or foreign scores")
        scores = [sc.get(f"{key}|{r['id']}") for r in rows]
        have = np.array([x is not None for x in scores])
        if haves and not np.array_equal(have, haves[0]):
            raise ValueError(f"{d} scored different mixtures than {dirs[0]} in {key}; compare only equal coverage")
        haves.append(have)
        scores = [x if x is not None else np.zeros(r["meta"]["frames"], np.float32) for x, r in zip(scores, rows)]
        ledgers.append(M.Ledger(tok, M.token_means(tok, scores)))
    if with_oracle:
        orc = EV.oracle_scores(fs, rows)
        ledgers.append(M.Ledger(tok, M.token_means(tok, [orc[r["id"]] for r in rows])))
    w_head = (haves[0] & np.isin(rel, EV.HEADLINE_RELATIONS) & primary).astype(np.float64)
    groups = {"pooled_all": None, "pooled_S1-S4": scen > 0, **{s: scen == i for i, s in enumerate(M.SCENARIOS)}}
    return M, EV, inv, universe, w_head, groups, ledgers


def system_points(set_id: str, half: str, dirs: Sequence[Path], cond=("builtin", False, 10), fs=None,
                  words=None) -> list[dict]:
    """Point metrics of each system on one shared population (equal coverage is
    required), each at its own tau calibrated on the pooled headline mixtures."""
    M, EV, inv, universe, w_head, groups, leds = _setup(set_id, half, cond, dirs, fs, words)
    out = []
    for led in leds:
        tau = led.calibrate(w_head)
        rem = led.removed(tau)
        out.append({"tau": tau, **{g: led.summarize(rem, w_head, msk) for g, msk in groups.items()}})
    return out


def paired(set_id: str, half: str, dir_a: Path, dir_b: Path, cond=("builtin", False, 10),
           group: str = SELECTION_METRIC[0], metric: str = SELECTION_METRIC[1], boot: int | None = None,
           fs=None, words=None) -> dict:
    """metric(A) - metric(B) at each system's own tau, with a joint-speaker paired CI."""
    M, EV, inv, universe, w_head, groups, (la, lb) = _setup(set_id, half, cond, (dir_a, dir_b), fs, words)
    out = _paired_ledgers(M, EV, inv, universe, w_head, groups[group], la, lb, metric, boot)
    return {"a": str(dir_a), "b": str(dir_b), "cond": list(cond), "group": group, "metric": metric, "half": half, **out}


def _paired_ledgers(M, EV, inv, universe, w_head, msk, la, lb, metric, boot) -> dict:
    boot = boot or EV.BOOT

    def stat(w: np.ndarray) -> float:
        ta, tb = la.calibrate(w), lb.calibrate(w)
        return la.summarize(la.removed(ta), w, msk)[metric] - lb.summarize(lb.removed(tb), w, msk)[metric]

    point = stat(w_head)
    rng = np.random.default_rng(EV.BOOT_SEED)
    vals = []
    for _ in range(boot):
        counts = np.bincount(rng.integers(0, len(universe), len(universe)), minlength=len(universe)).astype(np.float64)
        w = M.weights_from_counts(inv, counts) * w_head
        if w.sum() > 0:
            v = stat(w)
            if np.isfinite(v):
                vals.append(v)
    lo, hi = M.percentile_ci(np.array(vals))
    return {"point": float(point), "lo": float(lo), "hi": float(hi), "n_resamples": len(vals),
            "n_mixtures": int(w_head.sum())}


def s0_versus_oracle(set_id: str, half: str, dirs: Sequence[Path], cond=("builtin", False, 10), boot: int | None = None,
                     fs=None, words=None) -> list[dict]:
    """Per system: absolute S0 wer_increase, the oracle's on the same population,
    the oracle-relative increase (the G statistic, DESIGN.md section 7) and its
    paired joint-speaker CI (reported only; G uses the point)."""
    M, EV, inv, universe, w_head, groups, leds = _setup(set_id, half, cond, dirs, fs, words, with_oracle=True)
    orc = leds[-1]
    msk = groups["S0"]
    o_inc = orc.summarize(orc.removed(orc.calibrate(w_head)), w_head, msk)["wer_increase"]
    out = []
    for d, led in zip(dirs, leds[:-1]):
        a_inc = led.summarize(led.removed(led.calibrate(w_head)), w_head, msk)["wer_increase"]
        ci = _paired_ledgers(M, EV, inv, universe, w_head, msk, led, orc, "wer_increase", boot)
        out.append({"dir": str(d), "s0_wer_increase": float(a_inc), "oracle_s0_wer_increase": float(o_inc),
                    "relative": float(a_inc - o_inc), "relative_ci": [ci["lo"], ci["hi"]]})
    return out


def select_rule(names: Sequence[str], points: dict[str, float], g_ok: dict[str, bool],
                diff_ci_hi: Callable[[str, str], float], margin: float = MARGIN) -> dict:
    """DESIGN.md section 7. `names` in the fixed total order (smallest first).
    R = lowest point among candidates passing G (ties: earlier); the selection is
    the first candidate in order whose paired CI upper end of (candidate - R) is
    below `margin`; R qualifies trivially. Every comparison is against R."""
    ok = [n for n in names if g_ok[n]]
    if not ok:
        return {"selected": None, "reference": None, "reason": "no candidate passes G", "comparisons": {}}
    ref = min(ok, key=lambda n: (points[n], names.index(n)))
    comps = {}
    for n in ok:
        if n == ref:
            return {"selected": n, "reference": ref, "comparisons": comps}
        hi = diff_ci_hi(n, ref)
        comps[n] = hi
        if hi < margin:
            return {"selected": n, "reference": ref, "comparisons": comps}
    raise AssertionError("unreachable: the reference is always in the list")


def candidate_key(result_dir: Path) -> tuple[str, str, str]:
    """(size, conditioning, enroll_policy) of the checkpoint an evaluation scored,
    read from the run's run_meta.json; refuses non-default scorer options."""
    res = json.loads((Path(result_dir) / "results.json").read_text())
    args = res.get("args", {})
    if args.get("update_rule", "mean") != "mean" or args.get("recal"):
        raise ValueError(f"{result_dir}: selection uses the plain mean rule without recalibration")
    meta = json.loads((Path(args["checkpoint"]).parent / "run_meta.json").read_text())
    t = meta["train"]
    return (t["size"], t["conditioning"], t["enroll_policy"])


def order_candidates(dirs: Sequence[Path], key_of: Callable[[Path], tuple] = candidate_key) -> list[Path]:
    """Exactly the five candidates, once each, sorted into CANDIDATE_ORDER."""
    keyed = {key_of(Path(d)): Path(d) for d in dirs}
    if len(keyed) != len(dirs) or set(keyed) != set(CANDIDATE_ORDER):
        raise ValueError(f"selection needs exactly the candidates {CANDIDATE_ORDER}, got {sorted(keyed)}")
    return [keyed[k] for k in CANDIDATE_ORDER]


def select(set_id: str, half: str, dirs: Sequence[Path], fs=None, words=None,
           key_of: Callable[[Path], tuple] = candidate_key) -> dict:
    """DESIGN.md section 7 on half A. Points, G and paired CIs are all computed
    here, from the saved scores on one shared population."""
    if half != "A":
        raise ValueError("selection runs on dev half A only (DESIGN.md section 7)")
    ordered = order_candidates(dirs, key_of)
    names = [str(d) for d in ordered]
    pts = dict(zip(names, system_points(set_id, half, ordered, fs=fs, words=words)))
    points = {n: float(p[SELECTION_METRIC[0]][SELECTION_METRIC[1]]) for n, p in pts.items()}
    s0 = dict(zip(names, s0_versus_oracle(set_id, half, ordered, fs=fs, words=words)))
    g_ok = {n: bool(s0[n]["relative"] < G_LIMIT) for n in names}
    details = {}

    def hi(a: str, b: str) -> float:
        details[a] = paired(set_id, half, Path(a), Path(b), fs=fs, words=words)
        return details[a]["hi"]

    out = select_rule(names, points, g_ok, hi)
    out.update({"order": [list(k) for k in CANDIDATE_ORDER], "points": points, "g_ok": g_ok, "s0_guardrail": s0,
                "paired": details,
                "set_id": set_id, "half": half, "margin": MARGIN})
    return out


def main() -> None:
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("pair")
    p.add_argument("--set", required=True)
    p.add_argument("--half", default="all", choices=["all", "A", "B"])
    p.add_argument("--a", required=True, type=Path)
    p.add_argument("--b", required=True, type=Path)
    p.add_argument("--cond", default="builtin,clean,10")
    p.add_argument("--group", default=SELECTION_METRIC[0])
    p.add_argument("--metric", default=SELECTION_METRIC[1])
    s = sub.add_parser("select")
    s.add_argument("--set", required=True)
    s.add_argument("--half", default="A")
    s.add_argument("--candidates", nargs="+", required=True, type=Path)
    a = ap.parse_args()
    if a.cmd == "pair":
        d, c, k = a.cond.split(",")
        print(json.dumps(paired(a.set, a.half, a.a, a.b, (d, c == "contaminated", int(k)), a.group, a.metric)))
    else:
        print(json.dumps(select(a.set, a.half, a.candidates), indent=1))


if __name__ == "__main__":
    main()
