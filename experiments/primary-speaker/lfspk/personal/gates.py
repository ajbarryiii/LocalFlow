"""Gates, interpretive checks, diagnostics and the selection rule (DESIGN 3, 6.2, 6.3, 7).

    ./python -m lfspk.personal.gates report --mac-dir DIR      # runs/W6/report.json

Every gate is evaluated on configuration P at step 1,000, target-present
renders, pooled over the 22 subjects, with the shared-resample joint
bootstrap of `boot` (CIs where a gate needs one). Nothing reported here
outside G1-G5 selects anything.
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path

import numpy as np

from lfspk import paths

from . import boot as B
from . import subjects as S

FAMILIES = ("S0", "N", "S1", "S2", "S3", "S4")
G1_MIN = 0.20
G2_FLOOR, G2_MARGIN = 0.45, -0.05
G3_FAMILY, G3_S0_MEAN, G3_S0_TAIL = 0.010, 0.001, 0.01
G3B_S0_USER, G3C_USER = 0.003, 0.020
G4A_MIN, G4B_MIN = 0.05, 0.025
X2_MARGIN = 0.02
D5_FRAC, D5_OVER, D5_OVER_S0 = 0.03, 0.001, 0.0005


def tail(over: np.ndarray) -> float:
    return float(np.quantile(over, 0.99, method="higher"))


class Ctx:
    def __init__(self, sc: dict, W: np.ndarray):
        self.sc, self.W = sc, W
        self.present = ~sc["absent"]

    def mask(self, fam: str, present: bool = True) -> np.ndarray:
        return (self.sc["family"] == fam) & (self.present if present else ~self.present)

    def cell(self, arm: str, name: str) -> np.ndarray:
        return self.sc["cells"][f"{arm}|{name}"]

    def summary(self, arm: str, name: str, present: bool = True) -> dict:
        x = self.cell(arm, name)
        out = {}
        for f in FAMILIES:
            m = self.mask(f, present)
            if not m.any():
                continue
            out[f] = {"frac": float(B.frac(np.ones(m.sum()), x[m, 0], x[m, 1])), "under": float(x[m, 1].mean()),
                      "over": float(x[m, 2].mean()), "tail": tail(x[m, 2]), "n": int(m.sum())}
        return out

    def contrast(self, arm: str, a: str, b: str, fam: str) -> dict:
        xa, xb = self.cell(arm, a), self.cell(arm, b)
        m = self.mask(fam)
        r = B.contrast(self.W, m, xa[:, 0], xa[:, 1], xb[:, 1])
        ru = {"under_a": float(xa[m, 1].mean()), "under_b": float(xb[m, 1].mean()), "over_a": float(xa[m, 2].mean()),
              "over_b": float(xb[m, 2].mean())}
        return {**r, **ru}

    def summary_ci(self, arm: str, name: str) -> dict:
        """Per family (present): frac, under and over with shared-resample CIs, and the S0-style tail (point)."""
        x = self.cell(arm, name)
        out = {}
        for f in FAMILIES:
            m = self.mask(f)
            out[f] = {"frac": B.frac_ci(self.W, m, x[:, 0], x[:, 1]), "under": B.mean_ci(self.W, m, x[:, 1]),
                      "over": B.mean_ci(self.W, m, x[:, 2]), "tail": tail(x[m, 2])}
        return out

    def contrast3(self, arm: str, a: str, b: str, fam: str) -> dict:
        """a - b in frac, under and over, each with its shared-resample CI (DESIGN 3, X1; code3-r1 M4)."""
        xa, xb = self.cell(arm, a), self.cell(arm, b)
        m = self.mask(fam)
        return {"frac": B.contrast(self.W, m, xa[:, 0], xa[:, 1], xb[:, 1]),
                "under": B.mean_contrast(self.W, m, xa[:, 1], xb[:, 1]),
                "over": B.mean_contrast(self.W, m, xa[:, 2], xb[:, 2])}

    def per_user(self, arm: str, name: str) -> dict:
        x = self.cell(arm, name)
        out = {}
        for s in S.pilot_order():
            ms = self.sc["subject"] == s
            out[s] = {f: float(x[ms & self.mask(f), 2].mean()) for f in FAMILIES}
        return out


def safety(ctx: Ctx, arm: str, name: str) -> dict:
    s = ctx.summary(arm, name)
    pu = ctx.per_user(arm, name)
    g3a = all(s[f]["over"] <= G3_FAMILY for f in FAMILIES) and s["S0"]["over"] <= G3_S0_MEAN and s["S0"]["tail"] <= G3_S0_TAIL
    fail_b = [u for u, v in pu.items() if not v["S0"] <= G3B_S0_USER]
    fail_c = [u for u, v in pu.items() if any(not v[f] <= G3C_USER for f in FAMILIES if f != "S0")]
    return {"G3a": bool(g3a), "G3b": not fail_b, "G3c": not fail_c, "G3b_failing": fail_b, "G3c_failing": fail_c,
            "pooled": {f: {"over": s[f]["over"], "tail": s[f]["tail"]} for f in FAMILIES}, "per_user": pu}


def n_eff_and_spread(ctx: Ctx, arm: str, fam: str = "S4") -> dict:
    """n_eff = 1 / sum w_i^2 with w_i subject i's share of identity under-suppression; per-subject gains d_i."""
    p, c = ctx.cell(arm, "P1000|personal"), ctx.cell(arm, "P1000|control")
    m = ctx.mask(fam)
    tot = p[m, 0].sum()
    w, d = [], []
    for s in S.pilot_order():
        ms = m & (ctx.sc["subject"] == s)
        w.append(p[ms, 0].sum() / tot)
        d.append((c[ms, 1].sum() - p[ms, 1].sum()) / p[ms, 0].sum())
    w = np.asarray(w)
    return {"n_eff": float(1.0 / np.sum(w ** 2)), "d_i": dict(zip(S.pilot_order(), map(float, d))),
            "d_sd": float(np.std(d, ddof=1)), "d_mean_unweighted": float(np.mean(d))}


def g5(arm: str, measures: list[dict], d5: dict | None) -> dict:
    """Every gated Mac run (2 subjects x 2 repetitions, P, 2 threads, background QoS) within budget, and D5 in tolerance."""
    from .macbench import MAC_SUBJECTS, within_budget

    want = {(s, r) for s in MAC_SUBJECTS for r in (1, 2)}
    eligible = [m for m in measures
                if m["arm"] == arm and m["config"] == "P" and m["threads"] == 2 and m["qos"] == "background"]
    keys = [(m["subject"], m["rep"]) for m in eligible]
    duplicates = sorted({k for k in keys if keys.count(k) > 1})  # code3-r1 M3: no record may overwrite another
    got = {k: m for k, m in zip(keys, eligible)}
    missing = sorted(want - set(got))
    failing = sorted(k for k, m in zip(keys, eligible) if not (m.get("exit_code") == 0 and m.get("within_budget", True)
                                                               and "parse_error" not in m and within_budget(m)))
    runs_ok = not missing and not duplicates and not failing  # EVERY eligible measured run must meet the budget
    d5_res = d5_check(arm, d5) if d5 is not None else {"ok": False, "reason": "d5.json missing"}
    return {"pass": bool(runs_ok and d5_res["ok"]), "runs_ok": bool(runs_ok), "missing": missing,
            "duplicates": duplicates, "failing": failing, "n_eligible": len(eligible),
            "runs": {f"{s}-r{r}": {k: got[(s, r)].get(k) for k in ("wall_s", "peak_footprint_bytes", "max_rss_bytes",
                                                                     "exit_code", "load_start", "load_end")}
                     for (s, r) in sorted(got)}, "d5": d5_res}


def d5_check(arm: str, d5: dict) -> dict:
    """D5 for one arm. `d5` is load_d5's {"results", "errors"} (or {"error"} when global provenance failed, which
    fails every arm). The arm needs, for both measured subjects, a valid nixos reference and both valid Mac
    repetitions within tolerance; another arm's problems and the Linux-CPU attribution runs never fail it."""
    from .macbench import MAC_SUBJECTS

    if "error" in d5:
        return {"ok": False, "reason": d5["error"]}
    res, errs = d5["results"], d5.get("errors", {})
    mine = {k: v for k, v in errs.items() if k.startswith(f"{arm}|")}
    required = [f"{arm}|{s}|{v}" for s in MAC_SUBJECTS for v in ("nixos", "mac-r1", "mac-r2")]
    missing = [k for k in required if k not in res]
    out, ok = {"errors": mine}, not missing
    for s in MAC_SUBJECTS:
        ref = res.get(f"{arm}|{s}|nixos")
        if ref is None:
            continue
        rm, fam, absent = np.asarray(ref["metrics"]), np.asarray(ref["family"]), np.asarray(ref["absent"], bool)
        for v in ("mac-r1", "mac-r2", "cpu"):
            x = res.get(f"{arm}|{s}|{v}")
            if x is None:
                continue
            xm = np.asarray(x["metrics"])
            row = {}
            for f in FAMILIES:
                m = (fam == f) & ~absent
                fr = lambda a: 1 - a[m, 1].mean() / a[m, 0].mean()  # noqa: E731
                row[f] = {"d_frac": float(fr(xm) - fr(rm)), "d_over": float(xm[m, 2].mean() - rm[m, 2].mean())}
            within = (all(abs(row[f]["d_frac"]) <= D5_FRAC for f in ("S1", "S2", "S3", "S4"))
                      and all(abs(row[f]["d_over"]) <= D5_OVER for f in FAMILIES) and abs(row["S0"]["d_over"]) <= D5_OVER_S0)
            row["within"] = bool(within)
            if v.startswith("mac"):  # the Linux-CPU attribution run is report-only
                ok &= within
            out[f"{s}|{v}"] = row
        r1, r2 = res.get(f"{arm}|{s}|mac-r1"), res.get(f"{arm}|{s}|mac-r2")
        if r1 is not None and r2 is not None:  # Mac run-to-run nondeterminism (report only; DESIGN 7)
            a1, a2 = np.asarray(r1["metrics"]), np.asarray(r2["metrics"])
            out[f"{s}|mac-r1-vs-r2"] = {"max_abs_metric_diff": float(np.max(np.abs(a1 - a2))),
                                        "identical": bool(np.array_equal(a1, a2))}
    return {"ok": bool(ok), "missing_or_invalid": missing, "rows": out}


def gate_table(ctx: Ctx, arm: str, pers: str, ctrl: str) -> dict:
    """G1-G4 for a personal/control cell pair (used report-only for configuration F)."""
    sp = ctx.summary(arm, pers)
    g2c = ctx.contrast(arm, pers, "base", "S3")
    saf = safety(ctx, arm, pers)
    a, b = ctx.contrast(arm, pers, ctrl, "S4"), ctx.contrast(arm, pers, ctrl, "S2")
    return {"G1": all(sp[f]["frac"] >= G1_MIN for f in ("S1", "S2", "S4")),
            "G2": bool(sp["S3"]["frac"] >= G2_FLOOR and g2c["ci"]["resolved"] and g2c["ci"]["lo"] > G2_MARGIN),
            "G3a": saf["G3a"], "G3b": saf["G3b"], "G3c": saf["G3c"],
            "G4a": bool(a["point"] >= G4A_MIN and a["ci"]["resolved"] and a["ci"]["lo"] > 0), "G4b": bool(b["point"] >= G4B_MIN)}


def arm_report(ctx: Ctx, arm: str, measures: list[dict], d5: dict | None, cosines: dict | None = None) -> dict:
    P = "P1000|personal"
    sp = ctx.summary(arm, P)
    g1 = all(sp[f]["frac"] >= G1_MIN for f in ("S1", "S2", "S4"))
    g2c = ctx.contrast(arm, P, "base", "S3")
    g2 = sp["S3"]["frac"] >= G2_FLOOR and g2c["ci"]["resolved"] and g2c["ci"]["lo"] > G2_MARGIN
    saf = safety(ctx, arm, P)
    g4a_c = ctx.contrast(arm, P, "P1000|control", "S4")
    g4b_c = ctx.contrast(arm, P, "P1000|control", "S2")
    g4a = g4a_c["point"] >= G4A_MIN and g4a_c["ci"]["resolved"] and g4a_c["ci"]["lo"] > 0
    g4b = g4b_c["point"] >= G4B_MIN
    g5r = g5(arm, measures, d5)
    gates = {"G1": bool(g1), "G2": bool(g2), "G3a": saf["G3a"], "G3b": saf["G3b"], "G3c": saf["G3c"], "G4a": bool(g4a),
             "G4b": bool(g4b), "G5": g5r["pass"]}
    # X1: profile sensitivity (four cells, frac/under/over/tail, contrasts with CIs); wording fixed in DESIGN 3
    cells4 = {"W_A.pA": P, "W_B.pA": "P1000|control", "W_A.pB": "P1000|swapA", "W_B.pB": "P1000|swapB"}
    x1 = {"cells": {k: ctx.summary_ci(arm, v) for k, v in cells4.items()}, "contrasts": {}}
    for label, (a, b) in {"profile|W_A": (P, "P1000|swapA"), "profile|W_B": ("P1000|control", "P1000|swapB"),
                          "weights|pA": (P, "P1000|control"), "weights|pB": ("P1000|swapA", "P1000|swapB")}.items():
        x1["contrasts"][label] = {f: ctx.contrast3(arm, a, b, f) for f in FAMILIES}
    ps4 = x1["contrasts"]["profile|W_A"]["S4"]["frac"]["ci"]
    x1["wording"] = ("profile sensitivity observed" if ps4["resolved"] and (ps4["lo"] > 0 or ps4["hi"] < 0)
                     else "profile sensitivity not detected") + "; identity mechanism unresolved"
    # X2: control degradation
    sc_ = ctx.summary(arm, "P1000|control")
    sb = ctx.summary(arm, "base")
    x2 = {f: sc_[f]["frac"] - sb[f]["frac"] for f in FAMILIES}
    degraded = sc_["S4"]["frac"] < sb["S4"]["frac"] - X2_MARGIN
    x2r = {"control_minus_base": x2, "control_degraded": bool(degraded)}
    if degraded:
        x2r["personal_minus_base"] = {f: ctx.contrast(arm, P, "base", f) for f in FAMILIES}
    rep = {"gates": gates, "pass": all(gates.values()), "personal": sp, "G2_contrast": g2c, "G4a": g4a_c, "G4b": g4b_c,
           "G3": saf, "G5": g5r, "sizing": {**n_eff_and_spread(ctx, arm), "bootstrap_se_gain_S4": g4a_c["se"]},
           "X1": x1, "X2": x2r, "X3": {"control_safety": safety(ctx, arm, "P1000|control")},
           "base_safety": safety(ctx, arm, "base"),
           "base": sb, "control": sc_,
           "D1_twin": {f: ctx.contrast(arm, "base", "twin", f) for f in FAMILIES},
           "D3_drift": {"contrast": {f: ctx.contrast(arm, "P1000|drift", P, f) for f in FAMILIES},
                        "cos_p0_pend": cosines or {},
                        "cos_median": float(np.median(list(cosines.values()))) if cosines else None},
           "D4": {st: {"personal": ctx.summary(arm, f"P{st}|personal"), "control": ctx.summary(arm, f"P{st}|control"),
                       "gain_S4": ctx.contrast(arm, f"P{st}|personal", f"P{st}|control", "S4")} for st in (250, 500)},
           "D6_absent": {n: ctx.summary(arm, c, present=False) for n, c in (("personal", P), ("control", "P1000|control"),
                                                                            ("base", "base"))},
           "F": {"gates_report_only": gate_table(ctx, arm, "F1000|personal", "F1000|control"),
                 "personal": ctx.summary(arm, "F1000|personal"),
                 "G4a": ctx.contrast(arm, "F1000|personal", "F1000|control", "S4"),
                 "G4b": ctx.contrast(arm, "F1000|personal", "F1000|control", "S2"),
                 "safety": safety(ctx, arm, "F1000|personal")}}
    return rep


def select(reports: dict) -> dict:
    """DESIGN 6.3: the passing arm; if both pass, the higher mean frac over S1, S2, S4 (A-V0 within 0.01)."""
    passing = [a for a in ("A-V0", "A-VB") if reports[a]["pass"]]
    if not passing:
        return {"selected": None, "outcome": "neither arm passes"}
    if len(passing) == 1:
        return {"selected": passing[0], "outcome": "one arm passes"}
    m = {a: float(np.mean([reports[a]["personal"][f]["frac"] for f in ("S1", "S2", "S4")])) for a in passing}
    sel = "A-V0" if abs(m["A-V0"] - m["A-VB"]) < 0.01 else max(m, key=m.get)
    return {"selected": sel, "outcome": "both pass", "mean_frac_S1_S2_S4": m}


def report(mac_dir: Path, out: Path = paths.RUNS / "W6") -> dict:
    from .score import current_state, load_d5, load_scores

    current = current_state()
    sc = load_scores(current=current)
    universe = sorted(S.held_out(), key=int)
    inv = B.involvement_matrix(sc["involved"], universe)
    W = B.weights(inv, len(universe))
    ctx = Ctx(sc, W)
    measures = [json.loads(p.read_text()) for p in Path(mac_dir).rglob("measure.json")]
    try:
        d5 = load_d5(Path(mac_dir), current)  # validated against the current readouts and inputs (code3-r1 M2)
    except (FileNotFoundError, RuntimeError, KeyError) as e:
        d5 = {"error": f"{type(e).__name__}: {e}"}
    pj = json.loads((out / "profiles" / "profiles.json").read_text())
    cos = {s: v["cos_p0_pend"] for s, v in pj["subjects"].items()}
    reports = {arm: arm_report(ctx, arm, measures, d5, cos) for arm in S.ARMS}
    res = {"arms": reports, "selection": select(reports), "n_boot": B.N_BOOT, "universe": universe}
    (out / "report.json").write_text(json.dumps(res, indent=1, default=float))
    return res


def main(argv=None) -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("cmd", choices=("report", "coverage"))
    ap.add_argument("--mac-dir", default=str(paths.RUNS / "W6" / "mac"))
    a = ap.parse_args(argv)
    if a.cmd == "coverage":
        res = B.coverage_smoke()
        (paths.RUNS / "W6").mkdir(parents=True, exist_ok=True)
        (paths.RUNS / "W6" / "coverage_smoke.json").write_text(json.dumps(res, indent=1))
        print(json.dumps(res, indent=1))
        return
    res = report(Path(a.mac_dir))
    print(json.dumps({"selection": res["selection"], **{a: r["gates"] for a, r in res["arms"].items()}}, indent=1))


if __name__ == "__main__":
    main()
