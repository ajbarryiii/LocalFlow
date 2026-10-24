"""Freeze W5's evalwords (f6bea72) reference values for tests/test_W0_tmetrics.py.

    git show f6bea72:lfspk/extract/evalwords.py > /tmp/evalwords_f6bea72.py
    ./python tests/fixtures/freeze_W0_tmetrics_evalwords.py tests/fixtures/W0_tmetrics_evalwords_f6bea72.json /tmp/evalwords_f6bea72.py
"""
import importlib.util, json, sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[2]))
spec = importlib.util.spec_from_file_location("evalwords_f6bea72", sys.argv[2])
EW = importlib.util.module_from_spec(spec); sys.modules["evalwords_f6bea72"] = EW; spec.loader.exec_module(EW)
import numpy as np
from tests.test_W0_tmetrics import agreement_inputs, inputs_digest
mix30, cases = agreement_inputs()
out = {"source": "lfspk/extract/evalwords.py at f6bea72 (git blob), W5", "inputs_sha256": inputs_digest(mix30, cases)}
recs, means, mixtures, counts = [], [], [], []
for ref, ints, hyp, lab, mm in mix30:
    x_hyp = [h for h, m in zip(hyp, mm) if m >= 0.5]
    rec = EW.MixRecord("k", "S1", ("1",), ref, ints, lab)
    rec.hyps = {"B": hyp, "X": x_hyp}
    rec.evals = {s: EW.evaluate(h, ref, ints, lab) for s, h in rec.hyps.items()}
    rec.unreachable = EW.unreachable(hyp, ref)
    recs.append(rec); means.append(mm)
    e = rec.evals["X"]
    mixtures.append({"x_correct": sorted(e.correct), "unreachable": sorted(rec.unreachable), "x_SDI_int_other": [e.S, e.D, e.I, e.n_interferer, e.n_other]})
    counts.append(EW.per_mix_counts(rec, "X"))
summ = {k: v for k, v in EW.summarize(counts).items() if k in ("L+", "G", "G_u", "net_L", "E", "WER", "R", "other_per_ref")}
search = []
for budget in (0.005, 0.05, 0.2):
    tau, lp = EW.search_tau(recs, means, budget)
    search.append({"budget": budget, "tau": repr(float(tau)), "L+": lp})
out["mix30"] = {"mixtures": mixtures, "summary": summ, "search": search}
c150 = []
for mixes, budget in cases:
    rr, mm_ = [], []
    for ref, ints, hyp, lab, mm in mixes:
        rec = EW.MixRecord("k", "S1", ("1",), ref, ints, lab)
        rec.hyps = {"B": hyp}; rec.evals = {"B": EW.evaluate(hyp, ref, ints, lab)}
        rr.append(rec); mm_.append(mm)
    tau, lp = EW.search_tau(rr, mm_, budget)
    c150.append({"budget": budget, "tau": repr(float(tau)), "L+": lp})
out["cases150"] = c150
Path(sys.argv[1]).write_text(json.dumps(out, indent=1) + "\n")
print("taus:", sorted({c["tau"] for c in c150}), "inf cases", sum(c["tau"] == "inf" for c in c150))
