"""Pre-registered profile-direction check (DESIGN section 8):

    ./python -m lfspk.extract.profilecheck [--device cpu]

At evaluation W5 is conditioned on W1's profile direction (robust rule; a
dictation is the mean of unit 1.5 s window embeddings). It is trained on W3's
bank direction (the mean of whole-dictation embeddings). On 20 held-out train
speakers with 10 rendered dictations each:
- c_w1_bank = cos(W1 profile of the 10 dictations, bank-style profile of the same 10);
- c_within = cos(bank-style profile of dictations 1-5, bank-style profile of 6-10).
Decision: if median(c_w1_bank) >= median(c_within), W3's bank is used;
otherwise W5 builds a windowed bank with W1's `enroll_windows`.

Dictations are W3's own bank renders. They use the same bank utterances (the
first 10 in sha256 order of W3's `bank_utterances`), the W3 seed rule and the
built-in device. As a sanity check, their bank-style embeddings are compared
with the stored bank rows.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import time
from pathlib import Path

import numpy as np

from lfspk import paths

OUT = paths.RUNS / "W5" / "profilecheck"
N_SPEAKERS = 20
N_DICTATIONS = 10


def _h(s: str) -> str:
    return hashlib.sha256(s.encode()).hexdigest()


def decide(c_w1_bank, c_within) -> dict:
    a, b = float(np.median(c_w1_bank)), float(np.median(c_within))
    return {"median_cos_w1_vs_bank": a, "median_cos_within_bank": b,
            "decision": "use_w3_bank" if a >= b else "build_windowed_bank"}


def run(device: str = "cpu", out: Path = OUT) -> dict:
    from lfspk.embed.factory import make as w1_make
    from lfspk.harness.mix import MixtureGenerator
    from lfspk.pvad.bank_build import render_seed
    from lfspk.pvad.enrollment import bank_utterances, librispeech_partitions, mean_profile

    from .harness_frontend import W1_DEFAULTS
    from .overlay import held_out, load_w3_bank

    t0 = time.time()
    held = held_out()
    speakers = sorted(held, key=lambda s: _h(f"w5-pdc/{s}"))[:N_SPEAKERS]
    parts = librispeech_partitions("train")
    bank, _ = load_w3_bank()
    gen = MixtureGenerator("train")  # S0 renders: no other speaker roles
    scorer = w1_make(device=device, cache="0", **W1_DEFAULTS)
    rows = []
    for spk in speakers:
        utts = sorted(bank_utterances(parts[spk], 40), key=lambda u: _h(f"w5-pdc/{u}"))[:N_DICTATIONS]
        if len(utts) < N_DICTATIONS:
            raise ValueError(f"{spk} has only {len(utts)} bank utterances")
        dicts = []
        for u in utts:
            m = gen.render_paired(("S0", "S4"), render_seed(u, "builtin"), target=u, device="builtin",
                                  rir_mode="coherent")["S0"]
            dicts.append(m.audio)
        emb = scorer.embedder.embed_batch(dicts)
        stored = np.stack([bank.emb[bank.row(spk, u, "builtin", False)] for u in utts]).astype(np.float32)
        d_w1 = np.asarray(scorer.enroll(dicts).directions[0], dtype=np.float32)
        p_bank = mean_profile(emb)
        p_a, p_b = mean_profile(emb[:5]), mean_profile(emb[5:])
        rows.append({"speaker": spk, "cos_w1_vs_bank": float(d_w1 @ p_bank), "cos_within_bank": float(p_a @ p_b),
                     "min_cos_vs_stored_rows": float(np.min(np.sum(emb * stored, axis=1)))})
    res = {**decide([r["cos_w1_vs_bank"] for r in rows], [r["cos_within_bank"] for r in rows]),
           "speakers": rows, "w1_settings": W1_DEFAULTS, "elapsed_s": round(time.time() - t0, 1)}
    out.mkdir(parents=True, exist_ok=True)
    (out / "result.json").write_text(json.dumps(res, indent=1))
    return res


def main(argv=None) -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--device", default="cpu")
    a = ap.parse_args(argv)
    r = run(a.device)
    print(json.dumps({k: v for k, v in r.items() if k != "speakers"}, indent=1))


if __name__ == "__main__":
    main()
