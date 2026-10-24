"""Markdown tables for RESULTS.md, generated from the run outputs (no hand-copied numbers).

    ./python -m lfspk.protect.report invert > /tmp/invert.md
"""

from __future__ import annotations

import argparse
import json
import sys

from .. import paths
from . import clone_exp

EMBEDDERS = ("redimnet2-b2", "ecapa-vox", "titanet-s")


def _ci(d: dict, digits: int = 3) -> str:
    return f"{d['mean']:.{digits}f} [{d['lo']:.{digits}f}, {d['hi']:.{digits}f}]"


def invert_table(embedder: str, rows: list[str] | None = None) -> str:
    root = paths.RUNS / "W4" / "invert" / embedder
    ev = clone_exp.selection_evidence([embedder], {embedder: ["raw"]}, root.parent)[embedder]
    budget = {r["protection"]: r for r in ev["rows"]}
    names = rows or [r["protection"] for r in ev["rows"]]
    out = [f"**{embedder}** (dev, 73 speakers; raw EER {ev['budget']['raw_eer_crop_k10']:.4f}, "
           f"raw minDCF {ev['budget']['raw_mindcf']:.4f}; budget: EER <= 1.15 x raw and minDCF <= raw + 0.02)",
           "",
           "| protection | bytes | EER 2 s, k=10 [95 % CI] | minDCF | in budget | attacker (sel. on train) "
           "| cos to true profile | top-1 of 73 | top-1 of 994 | spoof accept | sex acc. | clone_eval top-1 of 251 (point) |",
           "|---|---|---|---|---|---|---|---|---|---|---|---|"]
    for name in names:
        r = json.loads((root / f"{name}.json").read_text())
        u = r["utility"]["k10_crop"]["all"]
        s = r["selected"]
        ce = r.get("extra", {}).get("clone_eval", {}).get("selected", {})
        ce_top1 = f"{ce['top1_dev']['mean']:.3f}" if ce else "-"
        out.append(
            f"| {name} | {r['stored_bytes']} | {u['eer']:.4f} [{u['eer_ci'][0]:.4f}, {u['eer_ci'][1]:.4f}] "
            f"| {u['mindcf']:.3f} | {'yes' if budget[name]['within_utility_budget'] else 'no'} "
            f"| {r['selected_attacker']} | {_ci(s['cos_true'])} | {_ci(s['top1_dev'], 2)} | {_ci(s['top1_all'], 2)} "
            f"| {_ci(s['spoof_accept'], 2)} | {_ci(r['sex_accuracy'], 2)} | {ce_top1} |")
    return "\n".join(out) + "\n"


def main(argv: list[str] | None = None) -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("what", choices=("invert",))
    ap.add_argument("--rows", default="")
    args = ap.parse_args(argv)
    rows = [x for x in args.rows.split(",") if x] or None
    for e in EMBEDDERS:
        sys.stdout.write(invert_table(e, rows) + "\n")


if __name__ == "__main__":
    main()
