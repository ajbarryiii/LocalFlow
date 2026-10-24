"""Post-hoc (not pre-registered) target-dominance check of stage 3.

In W2-simplemix the target is a whole utterance and the interferer a 30-100 %
segment, so "the speaker who talks most" identifies the target without any
voiceprint; the unconditioned head can learn that. This regenerates each dev
mixture deterministically (same plans, keys and audio cache as stage3) to get
the ratio of interferer-active to target-active frames, and reports cond and
uncond heads on E for mixtures where the interferer talks at least as much as
0.7x the target ("balanced", S4-like) versus the rest.

    ./python -m lfspk.probe.dominance
"""

from __future__ import annotations

import json

import numpy as np

from . import SEED
from .audiocache import ROOT as CACHE_ROOT
from .audiocache import AudioCache
from .frames import dev_plans, make_example
from .framereport import N_BOOT
from .metrics import GroupedTrials, bootstrap, difference, resample_weights
from .select import dev_halves, dev_strata
from .stage3 import OUT
from .verify import load_feats

BALANCED = 0.7


def main() -> None:
    dsel = load_feats("m1", "dev")[2]
    plans = dev_plans(dsel["plans"], dsel["sex"], dev_halves(dev_strata(dsel["plans"], dsel["sex"], dsel["subset"])))
    cache = AudioCache(CACHE_ROOT / "dev")
    cache.verify()
    ratio, modes = [], []
    for p in plans:
        _, lab, info = make_example(p, cache.load, False)
        ratio.append(np.isin(lab, (2, 3)).sum() / max(1, np.isin(lab, (1, 3)).sum()))
        modes.append(info.mode)
    ratio = np.array(ratio)
    report = {"balanced_threshold": BALANCED, "n_mixtures": len(plans),
              "fraction_balanced": float((ratio >= BALANCED).mean()), "results": {}}
    for w, tap in (("m1", "tap5"), ("base", "tap6")):
        zs = [np.load(OUT / f"{w}-seed{s}" / "dev_scores.npz") for s in (1, 2, 3)]
        z = zs[0]
        if not np.array_equal(z["target"], np.array([p.target for p in plans])):
            raise ValueError("dev plans do not match the scored mixtures")
        lengths = z["lengths"]
        mix_of = np.repeat(np.arange(lengths.size), lengths)
        tspk = np.array([str(s) for s in z["target_speaker"]])
        ispk = np.array([str(s) for s in z["interferer_speaker"]])
        inside = sorted(map(str, z["half_E"]), key=int)
        gi = {s: i for i, s in enumerate(inside)}
        in_e = np.isin(tspk, inside) & np.isin(ispk, inside)
        for name, sel in (("balanced", ratio >= BALANCED), ("dominant", ratio < BALANCED),
                          ("turn", np.array(modes) == "turn"), ("overlap_mode", np.array(modes) == "overlap")):
            keep = np.isin(z["labels"], (1, 2, 3)) & (in_e & sel)[mix_of]
            idx = np.flatnonzero(keep)
            y = np.isin(z["labels"][idx], (1, 3))
            gt = np.array([gi.get(s, -1) for s in tspk])[mix_of[idx]]
            gj = np.array([gi.get(s, -1) for s in ispk])[mix_of[idx]]
            pairs, pidx = np.unique(np.stack([gt, gj], 1), axis=0, return_inverse=True)
            pidx = pidx.ravel()

            def stat_for(head):
                ts = [GroupedTrials(zz[f"score/{w}:{tap}:{head}"][idx].astype(np.float64), y, pidx, len(pairs))
                      for zz in zs]
                return lambda wg: np.mean([t.auc_eer(wg) for t in ts], axis=0)
            mult = resample_weights(len(inside), N_BOOT, SEED + 2)
            weigh = lambda m: m[pairs[:, 0]] * m[pairs[:, 1]]  # noqa: E731
            out = {"mixtures": int((in_e & sel).sum()), "frames": int(idx.size)}
            for label, stat in (("cond", stat_for("cond")), ("uncond", stat_for("uncond")),
                                ("cond_minus_uncond", difference(stat_for("cond"), stat_for("uncond")))):
                est = bootstrap(stat, weigh, mult)
                out[label] = {"auc": est[0].as_dict(), "fa_at_miss2": est[3].as_dict()}
            report["results"].setdefault(w, {})[name] = out
            print(w, tap, name, out["mixtures"], {k: (round(v["auc"]["value"], 3), round(v["fa_at_miss2"]["value"], 3))
                                                 for k, v in out.items() if isinstance(v, dict)}, flush=True)
    (OUT / "dominance.json").write_text(json.dumps(report, indent=1))


if __name__ == "__main__":
    main()
