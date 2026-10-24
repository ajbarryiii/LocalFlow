"""Stage 2b metrics (CPU job): EER and minDCF with two-way speaker-bootstrap CIs,
tap selection on dev half S, and the pre-stated comparisons of DESIGN 5.5
reported on dev half E.

    ./python -m lfspk.probe.report

Writes RUNS/W2/verify/report.json and report.md.
"""

from __future__ import annotations

import argparse
import json
from concurrent.futures import ProcessPoolExecutor
from dataclasses import dataclass
from pathlib import Path

import numpy as np

from lfspk import paths

from . import SEED
from .metrics import SortedTrials, bootstrap, resample_weights, two_way
from .select import LENGTHS, SESSIONS

VERIFY = paths.RUNS / "W2" / "verify"
SUBSETS = ("all", "same_sex", "cross_chapter", "cross_project")
HALVES = ("full", "S", "E")
N_BOOT = 1000
SELECT_LENGTH = "2s"
H3_MARGIN = 0.01  # EER, absolute (1 point): equivalence margin for m1 vs base (DESIGN 4, H3)
DEFAULT_SYSTEMS = ["base", "m1", "logmel", "titanet", "titanet-raw",
                   "base-colour", "m1-colour", "logmel-colour", "titanet-colour", "titanet-colour-raw"]


@dataclass
class Trials:
    index: np.ndarray  # flat indices into the [models, tests] matrix
    labels: np.ndarray
    g_enroll: np.ndarray
    g_test: np.ndarray
    n_groups: int
    strata: np.ndarray  # session class per group

    def weigh(self):
        return two_way(self.g_enroll, self.g_test, self.labels)


def half_speakers(meta: dict, half: str) -> list[str]:
    speakers = [str(s) for s in meta["speakers"]]
    if half == "full":
        return speakers
    which = set(map(str, {"S": meta["half_S"], "E": meta["half_E"]}[half]))
    return [s for s in speakers if s in which]


def trial_set(meta: dict, subset: str, half: str = "full") -> Trials:
    """Trials of a subset restricted to one dev half (both speakers inside it).

      all: every trial;
      same_sex: target trials plus non-target trials whose speakers share sex;
      cross_chapter: enrollment speakers whose test material is from other
        chapters (cross_project or cross_chapter sessions);
      cross_project: enrollment speakers whose test material is from other
        LibriVox projects.
    Groups index the half's speakers (both roles), strata are their sessions.
    """
    for k in ("speakers", "sex", "session", "model_speaker", "test_speaker"):
        if np.asarray(meta[k]).ndim != 1:
            raise ValueError(f"bad trial metadata {k}")
    speakers = [str(s) for s in meta["speakers"]]
    sex = dict(zip(speakers, map(str, meta["sex"])))
    session = dict(zip(speakers, map(str, meta["session"])))
    inside = half_speakers(meta, half)
    gi = {s: i for i, s in enumerate(inside)}
    ms = np.array([str(s) for s in meta["model_speaker"]])
    ts = np.array([str(s) for s in meta["test_speaker"]])
    labels = ms[:, None] == ts[None, :]
    keep = np.isin(ms, inside)[:, None] & np.isin(ts, inside)[None, :]
    if subset == "same_sex":
        msx = np.array([sex[s] for s in ms])
        tsx = np.array([sex[s] for s in ts])
        keep &= labels | (msx[:, None] == tsx[None, :])
    elif subset == "cross_chapter":
        keep &= np.isin(ms, [s for s in speakers if session[s] in ("cross_project", "cross_chapter")])[:, None]
    elif subset == "cross_project":
        keep &= np.isin(ms, [s for s in speakers if session[s] == "cross_project"])[:, None]
    elif subset != "all":
        raise ValueError(subset)
    ge = np.broadcast_to(np.array([gi.get(s, -1) for s in ms])[:, None], labels.shape)
    gt = np.broadcast_to(np.array([gi.get(s, -1) for s in ts])[None, :], labels.shape)
    idx = np.flatnonzero(keep.ravel())
    strata = np.array([SESSIONS.index(session[s]) for s in inside])
    return Trials(idx, labels.ravel()[idx], ge.ravel()[idx], gt.ravel()[idx], len(inside), strata)


def multiplicities(meta: dict, half: str) -> np.ndarray:
    """Shared stratified resamples per half: every comparison within a half is paired."""
    t = trial_set(meta, "all", half)
    return resample_weights(t.n_groups, N_BOOT, SEED + HALVES.index(half), strata=t.strata)


def load_scores(system: str, root: Path = VERIFY):
    z = np.load(root / system / "scores.npz", allow_pickle=False)
    meta = {k.split("/", 1)[1]: z[k] for k in z.files if k.startswith("meta/")}
    mats = {k: z[k] for k in z.files if not k.startswith("meta/")}
    return mats, meta


def _sorted(scores: np.ndarray, t: Trials) -> SortedTrials:
    return SortedTrials(scores.ravel()[t.index].astype(np.float64), t.labels)


_UNDEFINED = {"value": float("nan"), "lo": float("nan"), "hi": float("nan")}


def _one(args):
    key, scores, meta, subset, half = args
    t = trial_set(meta, subset, half)
    counts = {"targets": int(t.labels.sum()), "nontargets": int((~t.labels).sum()), "speakers": t.n_groups}
    if not counts["targets"] or not counts["nontargets"]:
        return key, half, subset, {"eer": _UNDEFINED, "min_dcf": _UNDEFINED, **counts}
    st = _sorted(scores, t)
    est = bootstrap(st.eer_dcf, t.weigh(), multiplicities(meta, half))
    return key, half, subset, {"eer": est[0].as_dict(), "min_dcf": est[1].as_dict(), **counts}


def _diff(args):
    """args: (name, length, subset, half, meta, [(sign, scores), ...]) -> EER/minDCF of the signed sum."""
    name, length, subset, half, meta, terms = args
    t = trial_set(meta, subset, half)
    if t.labels.all() or not t.labels.any():
        return name, length, subset, half, {"eer": _UNDEFINED, "min_dcf": _UNDEFINED}
    sts = [(sign, _sorted(sc, t)) for sign, sc in terms]

    def stat(w):
        return sum(sign * np.asarray(st.eer_dcf(w)) for sign, st in sts)
    est = bootstrap(stat, t.weigh(), multiplicities(meta, half))
    return name, length, subset, half, {"eer": est[0].as_dict(), "min_dcf": est[1].as_dict()}


def best_tap(table: dict, system: str, half: str = "S") -> str:
    """argmin of the point EER at SELECT_LENGTH on all trials of `half` (ties: lower tap)."""
    taps = table[system]
    return min(taps, key=lambda tp: (taps[tp][half][SELECT_LENGTH]["all"]["eer"]["value"], int(tp[3:])))


def main(argv=None) -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--systems", nargs="*", default=DEFAULT_SYSTEMS)
    ap.add_argument("--workers", type=int, default=8)
    ap.add_argument("--root", type=Path, default=VERIFY)
    ap.add_argument("--quiet", action="store_true")
    args = ap.parse_args(argv)
    root = args.root
    loaded = {s: load_scores(s, root) for s in args.systems if (root / s / "scores.npz").exists()}
    if not loaded:
        raise FileNotFoundError(f"no scores under {root}")
    metas = [m for _, m in loaded.values()]
    for m in metas[1:]:
        for k in ("model_speaker", "test_speaker", "test_utt", "speakers", "session", "half_S", "half_E"):
            if not np.array_equal(m[k], metas[0][k]):
                raise ValueError(f"systems disagree on trial metadata {k}")
    meta = metas[0]
    tasks = [((sys, key), mats[key], meta, subset, half)
             for sys, (mats, _) in loaded.items() for key in mats for subset in SUBSETS for half in HALVES]
    table: dict = {}
    with ProcessPoolExecutor(args.workers) as ex:
        for (sys, key), half, subset, res in ex.map(_one, tasks, chunksize=4):
            tap, length = key.split("/")
            table.setdefault(sys, {}).setdefault(tap, {}).setdefault(half, {}).setdefault(length, {})[subset] = res
    report: dict = {"table": table, "n_boot": N_BOOT, "seed": SEED, "bootstrap": "two-way, stratified by session",
                    "selection": f"argmin EER({SELECT_LENGTH}, all) on dev half S; comparisons on half E",
                    "best_tap": {}, "comparisons": {}}
    for sys in ("base", "m1"):
        if sys in loaded:
            report["best_tap"][sys] = best_tap(table, sys)

    def sc(sys, tap, length):
        return loaded[sys][0][f"{tap}/{length}"]

    diffs = []  # (name, [(sign, system, tap)])
    if "base" in loaded:
        b = report["best_tap"]["base"]
        for other in ("titanet-raw", "titanet", "logmel"):
            if other in loaded:
                diffs.append((f"base:{b} - {other}", [(1, "base", b), (-1, other, "tap0")]))
        if "m1" in loaded:
            diffs.append((f"m1:{b} - base:{b}", [(1, "m1", b), (-1, "base", b)]))
            mb = report["best_tap"]["m1"]
            if "titanet-raw" in loaded:
                diffs.append((f"m1:{mb} - titanet-raw", [(1, "m1", mb), (-1, "titanet-raw", "tap0")]))
        if "base-colour" in loaded:
            diffs.append((f"colour degradation base:{b}", [(1, "base-colour", b), (-1, "base", b)]))
        if "titanet-colour-raw" in loaded and "titanet-raw" in loaded:
            diffs.append(("colour degradation titanet-raw",
                          [(1, "titanet-colour-raw", "tap0"), (-1, "titanet-raw", "tap0")]))
            if "base-colour" in loaded:
                diffs.append((f"colour degradation base:{b} - titanet-raw",
                              [(1, "base-colour", b), (-1, "base", b), (-1, "titanet-colour-raw", "tap0"),
                               (1, "titanet-raw", "tap0")]))
    dtasks = [(name, length, subset, half, meta, [(sg, sc(sy, tp, length)) for sg, sy, tp in terms])
              for name, terms in diffs for length in LENGTHS for subset in SUBSETS for half in ("E", "full")]
    with ProcessPoolExecutor(args.workers) as ex:
        for name, length, subset, half, res in ex.map(_diff, dtasks):
            report["comparisons"].setdefault(name, {}).setdefault(half, {}).setdefault(length, {})[subset] = res
    if "base" in loaded and "m1" in loaded:
        b = report["best_tap"]["base"]
        report["h3"] = h3_verdict(report["comparisons"][f"m1:{b} - base:{b}"]["E"][SELECT_LENGTH]["all"]["eer"])
    (root / "report.json").write_text(json.dumps(report, indent=1))
    (root / "report.md").write_text(markdown(report))
    if not args.quiet:
        print(markdown(report))


def h3_verdict(d: dict, margin: float = H3_MARGIN) -> dict:
    """Equivalence needs the whole CI inside (-margin, margin); a CI excluding 0
    is a difference; anything else is inconclusive (not 'no change')."""
    if -margin < d["lo"] and d["hi"] < margin:
        verdict = "equivalent within margin"
    elif d["lo"] > 0 or d["hi"] < 0:
        verdict = "different"
    else:
        verdict = "inconclusive"
    return {"margin": margin, "difference": d, "verdict": verdict}


def _fmt(e: dict, pct: bool = True) -> str:
    f = 100.0 if pct else 1.0
    return f"{e['value'] * f:.2f} [{e['lo'] * f:.2f}, {e['hi'] * f:.2f}]"


def markdown(report: dict) -> str:
    lines = ["EER % [95 % CI] / minDCF(0.01) [CI], dev (dev-clean + dev-other), two-way speaker bootstrap stratified by session.",
             f"Selection: {report['selection']}. Half 'full' is exploratory.", ""]
    for sys, taps in report["table"].items():
        for half in HALVES:
            lines += [f"### {sys}, half {half}", "",
                      "| tap | subset | " + " | ".join(f"EER {l} | minDCF {l}" for l in LENGTHS) + " |",
                      "|---|---|" + "---|---|" * len(LENGTHS)]
            for tap in sorted(taps, key=lambda t: int(t[3:])):
                for subset in SUBSETS:
                    cells = []
                    for length in LENGTHS:
                        r = taps[tap][half][length][subset]
                        cells += [_fmt(r["eer"]), _fmt(r["min_dcf"], pct=False)]
                    lines.append(f"| {tap[3:]} | {subset} | " + " | ".join(cells) + " |")
            lines.append("")
    lines += [f"best tap on S: {report['best_tap']}", ""]
    if "h3" in report:
        h = report["h3"]
        lines += [f"H3 (m1 vs base at the base tap, half E, {SELECT_LENGTH}): {h['verdict']}, margin "
                  f"{h['margin'] * 100:.1f} pts, difference {_fmt(h['difference'])} pts", ""]
    lines += ["### paired differences (signed sums; EER in points)", ""]
    for name, by_half in report["comparisons"].items():
        for half, by_len in by_half.items():
            for length, by_sub in by_len.items():
                for subset, r in by_sub.items():
                    lines.append(f"- {name}, half {half}, {length}, {subset}: EER {_fmt(r['eer'])}, "
                                 f"minDCF {_fmt(r['min_dcf'], pct=False)}")
    return "\n".join(lines) + "\n"


if __name__ == "__main__":
    main()
