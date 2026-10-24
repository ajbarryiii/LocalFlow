"""Bypass threshold theta_b (DESIGN section 7) and the held-out monitor (section 8),
both on held-out train speakers only.

    ./python -m lfspk.extract.calibrate render --set theta   --workers 6   # 500 S0 renders, k = 10 clean matched profiles
    ./python -m lfspk.extract.calibrate render --set monitor --workers 6   # 200 per family, training policy
    ./python -m lfspk.extract.calibrate theta   --checkpoint final.pt     # writes theta_b.json beside the checkpoint
    ./python -m lfspk.extract.calibrate monitor --checkpoint final.pt     # writes monitor.json (logged, never used for a choice)

theta_b = the 99th percentile (numpy method "higher", an observed value) of
max_t ubar(t) over the 500 S0 renders. A recording is bypassed iff its
max_t ubar < theta_b, so at most about 1 % of these clean recordings reach the
mask. The conditioning profiles come from W3's draw at k = 10, clean, on the
mixture's device (bank-style, as in training).

Renders are bound to a set identity (seed, policy, held-out set, bank and
held-out overlay, render code, W0 and W3 code), with a manifest of exact keys,
audio hashes and per-sample conditions; theta and monitor validate all of it
(implT-r1 #4). Profiles come from the held-out bank scope, so a contaminated
monitor profile only ever contains held-out voices (implT-r1 #5); theta_b's
profiles are clean, matched, k = 10 and are validated as such.

The monitor is computed after training on the final checkpoint rather than
during it. It records the log-mask error split into over- and under-suppression,
and u's frame ROC AUC against the identity-relative labels, per family. The
DESIGN placed the monitor during training. It never feeds a choice, so only
its timing changes.
"""

from __future__ import annotations

import argparse
import json
import os
import time
from pathlib import Path

import numpy as np

from lfspk import paths

from .data import FAMILIES

OUT = paths.RUNS / "W5" / "calib"
SETS = {"theta": dict(seed=20261023, families=("S0",), n=500),
        "monitor": dict(seed=20261024, families=FAMILIES, n=200)}

_SRC: dict = {}

THETA_ENROLL = dict(k_choices=(10,), contamination_rates=(0.0,), contamination_probs=(1.0,), p_match_channel=1.0)


def _policy(set_name: str):
    from lfspk.pvad.enrollment import EnrollPolicy

    from .data import ExamplePolicy

    if set_name == "theta":
        return ExamplePolicy(p_absent=0.0, enroll=EnrollPolicy(**THETA_ENROLL))
    return ExamplePolicy()


def _source(set_name: str):
    if set_name not in _SRC:
        from lfspk.harness.mix import MixtureGenerator
        from lfspk.pvad.enrollment import librispeech_partitions

        from .data import ExampleSource
        from .overlay import held_out, load_bank

        held = held_out()
        # the held-out bank: every contaminated twin of a held-out speaker has held-out contaminators only
        bank, _ = load_bank(scope="heldout")
        gen = MixtureGenerator("train", speakers=list(held))
        # excluding every non-held-out bank speaker keeps absent-target impostors among the held-out speakers too
        others = [s for s in bank.speakers() if s not in set(held)]
        _SRC[set_name] = (ExampleSource(gen, librispeech_partitions("train"), bank, held, others, _policy(set_name)),
                          set(held))
    return _SRC[set_name]


def expected_keys(set_name: str) -> list[str]:
    spec = SETS[set_name]
    return [f"{f}-{i:03d}" for f in spec["families"] for i in range(spec["n"])]


def set_identity(set_name: str) -> dict:
    """Everything a calibration set depends on (implT-r1 #4)."""
    import hashlib
    from dataclasses import asdict

    from lfspk.pvad.identity import w0_identity

    from .overlay import OUT_DIR, W3_BANK_SHA256, held_out
    from .train import w3_code_sha256

    ov = json.loads((OUT_DIR / "overlay_heldout_meta.json").read_text())
    spec = SETS[set_name]
    return json.loads(json.dumps({
        "kind": "w5-calibration-set", "set": set_name, "seed": spec["seed"], "families": list(spec["families"]),
        "n": spec["n"], "index_rule": "FAMILIES.index(family) * 100000 + i", "policy": asdict(_policy(set_name)),
        "held_out_sha256": hashlib.sha256(",".join(sorted(held_out(), key=int)).encode()).hexdigest(),
        "w3_bank_sha256": W3_BANK_SHA256, "heldout_overlay_sha256": ov["overlay_sha256"], "w0": w0_identity("train"),
        "render_code_sha256": render_code_sha256(), "w3_code_sha256": w3_code_sha256()}))


RENDER_FILES = ("api.py", "data.py", "overlay.py", "calibrate.py")


def render_code_sha256(files=RENDER_FILES) -> str:
    """W5 code a calibration render depends on, calibrate.py included: its
    _source and _render_one choose the speaker pools and the examples (implT-r2 #2)."""
    from .train import files_sha256

    here = Path(__file__).resolve().parent
    return files_sha256([here / f for f in files], here)


def _render_one(job):
    set_name, fam, i, out = job
    src, held = _source(set_name)
    spec = SETS[set_name]
    ex = src.example(spec["seed"], FAMILIES.index(fam) * 100_000 + i, family=fam)
    who = {ex.info["speaker"], *ex.info["interferers"]} | ({ex.info["impostor"]} if ex.info["impostor"] else set())
    if who - held:
        raise AssertionError("a calibration mixture involves a speaker outside the held-out set")
    key = f"{fam}-{i:03d}"
    tmp = Path(out) / f"{key}.tmp.npz"
    np.savez(tmp, audio=ex.audio, target_image=ex.target_image, noise=ex.noise, interfering=ex.interfering,
             profile=ex.profile, info=np.array(json.dumps(ex.info)))
    os.replace(tmp, Path(out) / f"{key}.npz")
    return key


CONDITION_FIELDS = ("family", "absent", "k", "contamination_rate", "contaminated", "matched")


def render(set_name: str, workers: int, out: Path = OUT) -> None:
    from multiprocessing import get_context

    from .stage0 import _sha, audio_sha256, persisted_identity, prepare_render_dir

    root = out / set_name
    keys = expected_keys(set_name)
    ident = set_identity(set_name)
    todo = prepare_render_dir(root, ident, keys)
    jobs = [(set_name, k.split("-")[0], int(k.split("-")[1]), str(root / "mix")) for k in todo]
    with get_context("spawn").Pool(workers) as p:
        for k, _ in enumerate(p.imap_unordered(_render_one, jobs, chunksize=2)):
            if (k + 1) % 100 == 0:
                print(json.dumps({"rendered": k + 1, "of": len(jobs)}), flush=True)
    have = sorted(p.stem for p in (root / "mix").glob("*.npz"))
    if have != sorted(keys):
        raise RuntimeError("renders do not match the expected keys")
    hashes, conds = {}, {}
    for k in keys:
        d = _load(root / "mix" / f"{k}.npz")
        hashes[k] = audio_sha256(d["audio"])
        conds[k] = {f: d["info"][f] for f in CONDITION_FIELDS}
    # bound to the PERSISTED identity (sol stepbudget-r2 #1)
    (root / "render.json").write_text(json.dumps({"identity_sha256": _sha(persisted_identity(root)), "keys": hashes,
                                                  "conditions": conds},
                                                 indent=1))


def _load(path: Path) -> dict:
    z = np.load(path, allow_pickle=False)
    return {k: z[k] for k in ("audio", "target_image", "noise", "interfering", "profile")} | {"info": json.loads(str(z["info"]))}


def load_set(set_name: str, out: Path = OUT, set_identity_fn=None):
    """Yield (key, sample) of a complete calibration set, validated against its
    identity, exact keys, audio hashes and recorded conditions (implT-r1 #4)."""
    from .stage0 import audio_sha256, read_manifest

    root = out / set_name
    stored = json.loads((root / "render_identity.json").read_text())
    current = (set_identity_fn or set_identity)(set_name)
    from .identities import differing, same

    if not same(stored, current):  # the CURRENT identity, not just the stored pair (implI2-r2 #2-#3)
        raise RuntimeError(f"{set_name}: renders were made under another identity "
                           f"(differs in {differing(stored, current)}); re-render")
    man = read_manifest(root)
    keys = expected_keys(set_name)
    if sorted(man["keys"]) != sorted(keys) or sorted(p.stem for p in (root / "mix").glob("*.npz")) != sorted(keys):
        raise RuntimeError(f"{set_name}: keys differ from the expected set")
    for k in keys:
        d = _load(root / "mix" / f"{k}.npz")
        if audio_sha256(d["audio"]) != man["keys"][k]:
            raise RuntimeError(f"{k}: audio differs from the manifest")
        if {f: d["info"][f] for f in CONDITION_FIELDS} != man["conditions"][k]:
            raise RuntimeError(f"{k}: conditions differ from the manifest")
        yield k, d


def check_theta_conditions(cond: dict) -> None:
    """The theta_b population: clean S0 target-only mixtures with a present
    target and a clean, matched profile of exactly 10 dictations."""
    want = {"family": "S0", "absent": False, "k": 10, "contamination_rate": 0.0, "contaminated": 0, "matched": 10}
    if any(cond.get(f) != v for f, v in want.items()):
        raise RuntimeError(f"a theta_b sample violates the population: {cond}")


def _analyse(net, audio: np.ndarray, profile: np.ndarray):
    """The same single-thread path as `ExtractFrontEnd.analyse` (harness_frontend.run_mask)."""
    from .harness_frontend import run_mask

    return run_mask(net, audio, profile)


def theta(checkpoint: Path, out: Path = OUT) -> dict:
    from .frontend import smooth_u
    from .harness_frontend import load_checkpoint

    net, meta, sha = load_checkpoint(checkpoint)
    mx = []
    for k, d in load_set("theta", out):
        check_theta_conditions({f: d["info"][f] for f in CONDITION_FIELDS})
        _, u = _analyse(net, d["audio"], d["profile"])
        n = len(d["audio"])
        mx.append(float(smooth_u(u, n)[: n // 160].max()))
    if len(mx) != SETS["theta"]["n"]:
        raise RuntimeError("theta_b needs exactly the 500 S0 samples")
    th = float(np.quantile(np.asarray(mx), 0.99, method="higher"))
    res = {"checkpoint": str(checkpoint), "checkpoint_sha256": sha, "theta_b": th, "n": len(mx),
           "set_identity_sha256": json.loads((out / "theta" / "render.json").read_text())["identity_sha256"],
           "share_bypassed_at_theta": float(np.mean(np.asarray(mx) < th)), "max_ubar_quantiles":
           {q: float(np.quantile(mx, q)) for q in (0.5, 0.9, 0.95, 0.99)},
           "created_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())}
    (Path(checkpoint).parent / "theta_b.json").write_text(json.dumps(res, indent=1))
    return res


def monitor(checkpoint: Path, out: Path = OUT) -> dict:
    import torch

    from lfspk.harness.metrics import exact_auc_eer

    from .api import valid_frames
    from .data import frame_labels
    from .frontend import ideal_log_mask, parakeet_mel_power
    from .harness_frontend import load_checkpoint

    net, meta, sha = load_checkpoint(checkpoint)
    kind = meta.get("identity", {}).get("target_kind", "T2")
    mel = parakeet_mel_power()
    acc: dict = {}
    for k, d in load_set("monitor", out):
        fam = d["info"]["family"]
        n = len(d["audio"])
        m = valid_frames(n)
        lm, u = _analyse(net, d["audio"], d["profile"])
        absent = bool(d["info"]["absent"])
        y = (d["noise"] if absent else d["target_image"] + d["noise"]) if kind == "T2" else \
            (np.zeros_like(d["audio"]) if absent else d["target_image"])
        with torch.no_grad():
            ideal = ideal_log_mask(mel(torch.from_numpy(np.ascontiguousarray(y, dtype=np.float32))[None]),
                                   mel(torch.from_numpy(d["audio"])[None]))[0].numpy()
        x = (ideal - lm)[:, :m]
        a = acc.setdefault(fam, {"over": [], "under": [], "u": [], "lab": []})
        a["over"].append(float(np.mean(np.clip(x, 0, None) ** 2)))
        a["under"].append(float(np.mean(np.clip(-x, 0, None) ** 2)))
        a["u"].append(u[:m])
        a["lab"].append(frame_labels(d["interfering"], n)[:m])
    res = {"checkpoint": str(checkpoint), "checkpoint_sha256": sha, "target_kind": kind, "families": {}}
    for fam, a in acc.items():
        lab = np.concatenate(a["lab"]).astype(bool)
        sc = np.concatenate(a["u"]).astype(np.float64)
        auc = float(exact_auc_eer(sc, lab)[0]) if lab.any() and (~lab).any() else None
        res["families"][fam] = {"n": len(a["over"]), "mean_sq_over_suppression": float(np.mean(a["over"])),
                                "mean_sq_under_suppression": float(np.mean(a["under"])), "u_frame_auc": auc}
    (Path(checkpoint).parent / "monitor.json").write_text(json.dumps(res, indent=1))
    return res


def main(argv=None) -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    r = sub.add_parser("render")
    r.add_argument("--set", choices=sorted(SETS), required=True)
    r.add_argument("--workers", type=int, default=6)
    for c in ("theta", "monitor"):
        s = sub.add_parser(c)
        s.add_argument("--checkpoint", type=Path, required=True)
    a = ap.parse_args(argv)
    if a.cmd == "render":
        render(a.set, a.workers)
    elif a.cmd == "theta":
        print(json.dumps(theta(a.checkpoint), indent=1))
    else:
        print(json.dumps(monitor(a.checkpoint), indent=1))


if __name__ == "__main__":
    main()
