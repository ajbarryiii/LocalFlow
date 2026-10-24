"""Pre-training augmentation audit (DESIGN 2.4), gating the start of the tuning runs.

    ./python -m lfspk.personal.audit run

On the first 2,000 examples of each of 4 subjects (first 2 F, first 2 M in
pilot order), against the bank donors themselves (W0 coherent) and 200 W0
mixed-mode renders per family (the audit reference set), per family S1-S4:
1. SIR after placement against SIR_D (by construction within 0.1 dB);
2. overlap: share of the target's active frames that are interferer-active;
3. channel distance: RMS over the 128 mel bins of the difference between the
   level-removed long-term mel spectra (dB) of target and interference, each
   averaged over its own active frames;
4. rejection counts and the padded share.
Stop rules (fixed in DESIGN 2.4):
- any |SIR - SIR_D| > 0.1 dB: a bug; stop until fixed;
- any family's median channel distance > the 95th percentile of its W0
  mixed-mode reference, or an S1/S2/S4 median overlap < half the donors'
  median overlap: stop before tuning and report to the orchestrator.
S3's overlap is reported only. Output runs/W6/audit/audit.json.
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path

import numpy as np

from lfspk import paths

from . import subjects as S

OUT = paths.RUNS / "W6" / "audit"
N_EXAMPLES = 2000
AUDIT_SUBJECTS = S.PILOT["F"][:2] + S.PILOT["M"][:2]
SIR_TOL_DB = 0.1
CHANNEL_Q = 0.95
OVERLAP_FRACTION = 0.5
GUARD = 1e-20  # far below any active bin's power, so the spectrum measures acoustics, not the feature log guard (2^-24)


def ltas_db(x: np.ndarray, active: np.ndarray, mel) -> np.ndarray:
    """Level-removed long-term mel spectrum (dB) over the frames where `active` is true.
    Feature frame i is contract frame i (W5's frame_labels convention)."""
    from lfspk.extract.frontend import mel_power_np

    p = mel_power_np(np.asarray(x, np.float32), mel).astype(np.float64)  # [128, N // 160 + 1]
    a = np.asarray(active, bool)
    t = min(p.shape[1], len(a))
    sel = np.flatnonzero(a[:t])
    if sel.size == 0:
        raise ValueError("no active frame for the spectrum")
    s = 10.0 * np.log10(p[:, sel] + GUARD).mean(axis=1)
    return s - s.mean()


def channel_distance(a: np.ndarray, a_act: np.ndarray, b: np.ndarray, b_act: np.ndarray, mel) -> float:
    return float(np.sqrt(np.mean((ltas_db(a, a_act, mel) - ltas_db(b, b_act, mel)) ** 2)))


def overlap_share(ta: np.ndarray, ia: np.ndarray) -> float:
    ta, ia = np.asarray(ta, bool), np.asarray(ia, bool)
    return float(np.sum(ta & ia) / max(1, ta.sum()))


def s3_kept_share(record: dict) -> float | None:
    """kept / c0 for an S3 placement (amendment A1); None (undefined) when the onset-aligned baseline c0 is 0,
    which A1 allows when another shift recovers >= 50 frames. Undefined ratios are counted, never summarised."""
    c0 = int(record["s3_baseline_frames"])
    return None if c0 == 0 else record["interf_active_frames"] / c0


def summary(x) -> dict:
    x = np.asarray([v for v in x if v is not None], dtype=np.float64)
    if x.size == 0:
        return {"n": 0}
    return {"n": int(x.size), "median": float(np.median(x)), "p05": float(np.quantile(x, 0.05)),
            "p95": float(np.quantile(x, 0.95)), "mean": float(x.mean()), "max": float(x.max())}


def verdict(tables: dict, sir_max_abs_err: float) -> dict:
    """The fixed stop rules on the per-family tables {fam: {"transplant": {...}, "donor": {...}, "mixed": {...}}}."""
    reasons = []
    if not sir_max_abs_err <= SIR_TOL_DB:
        return {"proceed": False, "kind": "bug", "reasons": [f"max |SIR - SIR_D| = {sir_max_abs_err:.4f} dB > {SIR_TOL_DB}"]}
    for fam, t in tables.items():
        if t["transplant"]["channel"]["median"] > t["mixed"]["channel"]["p95"]:
            reasons.append(f"{fam}: median channel distance {t['transplant']['channel']['median']:.3f} > mixed-mode p95 "
                           f"{t['mixed']['channel']['p95']:.3f}")
        if fam in ("S1", "S2", "S4") and t["transplant"]["overlap"]["median"] < OVERLAP_FRACTION * t["donor"]["overlap"]["median"]:
            reasons.append(f"{fam}: median overlap {t['transplant']['overlap']['median']:.3f} < half the donors' "
                           f"{t['donor']['overlap']['median']:.3f}")
    return {"proceed": not reasons, "kind": "method" if reasons else None, "reasons": reasons}


def run(out: Path = OUT) -> dict:
    from lfspk.extract.frontend import parakeet_mel_power

    from .render import load_set
    from .stream import Bank, load_dictations, make_example

    mel = parakeet_mel_power()
    bank = Bank(paths.RUNS / "W6" / "render" / "bank_pack")
    fams = ("S1", "S2", "S3", "S4")
    tr = {f: {"sir_err": [], "overlap": [], "channel": [], "padded": [], "rejections": [], "kept_share": [],
              "kept_share_undefined": 0} for f in fams}
    counts = {"examples": 0, "absent": 0, "S0": 0, "N": 0, "rejections_N": []}
    for spk in AUDIT_SUBJECTS:
        dicts = load_dictations(spk)
        for k in range(N_EXAMPLES):
            p = make_example(spk, k, dicts, bank)
            counts["examples"] += 1
            r = p.record
            if r["absent"]:
                counts["absent"] += 1
                continue
            if r["family"] in ("S0", "N"):
                counts[r["family"]] += 1
                if r["family"] == "N":
                    counts["rejections_N"].append(r["rejections"])
                continue
            t = tr[r["family"]]
            t["sir_err"].append(abs(r["sir_measured_db"] - r["sir_target_db"]))
            t["overlap"].append(r["overlap_share"])
            t["padded"].append(r["padded_share"])
            t["rejections"].append(r["rejections"])
            if "s3_baseline_frames" in r:  # amendment A1: the share of the onset-aligned interference kept
                ks = s3_kept_share(r)
                if ks is None:
                    t["kept_share_undefined"] += 1
                else:
                    t["kept_share"].append(ks)
            t["channel"].append(channel_distance(p.d_target, p.d_active, p.interf, p.interf_active, mel))
    don = {f: {"overlap": [], "channel": []} for f in fams}
    for f in fams:
        for i in range(bank.counts[f]):
            D = bank.get(f, i)
            don[f]["overlap"].append(overlap_share(D.target_active, D.interferer_active))
            don[f]["channel"].append(channel_distance(D.target, D.target_active, D.interf, D.interferer_active, mel))
    mixed = {f: {"overlap": [], "channel": []} for f in fams}
    for k, d in load_set("auditref"):
        f = d["info"]["family"]
        t32, i32 = d["target"].astype(np.float32), d["interf"].astype(np.float32)
        mixed[f]["overlap"].append(overlap_share(d["target_active"], d["interferer_active"]))
        mixed[f]["channel"].append(channel_distance(t32, d["target_active"], i32, d["interferer_active"], mel))
    tables = {f: {"transplant": {"overlap": summary(tr[f]["overlap"]), "channel": summary(tr[f]["channel"]),
                                 "sir_abs_err_db": summary(tr[f]["sir_err"]), "padded_share": summary(tr[f]["padded"]),
                                 "rejections_total": int(np.sum(tr[f]["rejections"])) if tr[f]["rejections"] else 0,
                                 "s3_kept_share": summary(tr[f]["kept_share"]),
                                 "s3_kept_share_undefined_c0_zero": tr[f]["kept_share_undefined"]},
                  "donor": {"overlap": summary(don[f]["overlap"]), "channel": summary(don[f]["channel"])},
                  "mixed": {"overlap": summary(mixed[f]["overlap"]), "channel": summary(mixed[f]["channel"])}}
              for f in fams}
    sir_max = max((max(tr[f]["sir_err"]) for f in fams if tr[f]["sir_err"]), default=float("nan"))
    res = {"subjects": list(AUDIT_SUBJECTS), "n_examples_per_subject": N_EXAMPLES, "counts": {
        **{k: v for k, v in counts.items() if k != "rejections_N"}, "rejections_N_total": int(np.sum(counts["rejections_N"]))},
        "bank_pack_sha256": bank.pack_sha256, "tables": tables, "sir_max_abs_err_db": sir_max,
        "verdict": verdict(tables, sir_max)}
    out.mkdir(parents=True, exist_ok=True)
    (out / "audit.json").write_text(json.dumps(res, indent=1))
    return res


N_STREAM = 8000  # 1,000 steps x batch 8: every tuning example of a run


def _dryrun_subject(spk: str, dicts=None, bank=None, n: int = N_STREAM) -> dict:
    """Every tuning example of subject spk (examples 0..7999, seed 0; the stream is shared by P and F), without
    features: counts rejections per family and fails loudly on donor exhaustion (erratum E1 check)."""
    from .stream import Bank, load_dictations, make_example

    bank = bank if bank is not None else Bank(paths.RUNS / "W6" / "render" / "bank_pack")
    dicts = dicts if dicts is not None else load_dictations(spk)
    rej = {f: [] for f in ("S1", "S2", "S3", "S4", "N")}
    by_dict = {}
    for k in range(n):
        r = make_example(spk, k, dicts, bank).record  # raises RuntimeError on 20 rejected donors
        if not r["absent"] and r["family"] in rej:
            rej[r["family"]].append(r["rejections"])
            by_dict.setdefault(r["dictation"], []).append(r["rejections"])
    return {"subject": spk, "examples": n,
            "rejections": {f: {"draws": len(v), "total": int(np.sum(v)), "max": int(max(v, default=0))} for f, v in rej.items()},
            "rejections_by_dictation": {int(j): {"draws": len(v), "total": int(np.sum(v)), "max": int(max(v))}
                                        for j, v in sorted(by_dict.items())}}


def dryrun(workers: int, out: Path = OUT) -> dict:
    from multiprocessing import get_context

    with get_context("spawn").Pool(workers) as p:
        res = p.map(_dryrun_subject, list(S.pilot_order()))
    from .stream import Bank

    agg = {"subjects": res, "bank_pack_sha256": Bank(paths.RUNS / "W6" / "render" / "bank_pack").pack_sha256,
           "max_rejections": max(r["rejections"][f]["max"] for r in res for f in r["rejections"])}
    out.mkdir(parents=True, exist_ok=True)
    (out / "stream_dryrun.json").write_text(json.dumps(agg, indent=1))
    return agg


def main(argv=None) -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("cmd", choices=("run", "dryrun"))
    ap.add_argument("--workers", type=int, default=4)
    a = ap.parse_args(argv)
    if a.cmd == "dryrun":
        res = dryrun(a.workers)
        print(json.dumps({"max_rejections": res["max_rejections"]}, indent=1))
        return
    res = run()
    print(json.dumps(res["verdict"], indent=1))


if __name__ == "__main__":
    main()
