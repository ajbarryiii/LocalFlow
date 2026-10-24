"""Scoring (DESIGN 6.1): W5's frozen screen measurement on the per-subject scoring sets.

    ./python -m lfspk.personal.score parity                  # must reproduce W5's screen table first (1e-9)
    ./python -m lfspk.personal.score subjects --workers 4    # every cell of every subject -> runs/W6/scores/
    ./python -m lfspk.personal.score d5 --mac-dir DIR        # D5: Mac-tuned and nixos-CPU-tuned models, 2 subjects

Per render, exactly as monitor_reference.v3.py (sha256 eae20c10...fffe2):
the T2 oracle y* = target image + noise (present) or noise (absent);
ideal = ideal_log_mask(P(y*), P(mix)) over valid frames; the model's log mask
from `run_mask` (one thread, raw C1); id_under = mean(ideal^2), under =
mean(clip(-(ideal - lm), 0)^2), over = mean(clip(ideal - lm, 0)^2).

Cells of subject A, per arm (B = A's control donor, pX = X's p0):
- base (pA), twin (no profile)                                   context, D1
- personal: W_A at steps 250/500/1000 (P) and 1000 (F), pA       gates, D4, F
- control: W_B, same steps and configurations, pA                gates, D4, F
- swapA: W_A (P, 1000) with pB; swapB: W_B (P, 1000) with pB     X1
- drift: W_A (P, 1000) with A's p_end                            D3
Every model is loaded through the pinned paths (tune.load_base / load_tuned),
and every tuned readout's identity must name the expected arm, configuration,
subject and step and the profile digest used here. Each subject's output is
bound to the scoring set's manifest, the profiles file and the code hashes.
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path

import numpy as np

from lfspk import paths

from . import subjects as S

OUT = paths.RUNS / "W6" / "scores"
STEPS = (250, 500, 1000)
# The calculation and reporting closure (code3-r2 M1): every W6 module, W5's extract package (run_mask, the mel front
# end, the ideal mask), and W0's bootstrap providers with their transitive imports (tmetrics -> align, metrics -> api).
CLOSURE = {"w6": ("lfspk/personal", "*.py"), "w5": ("lfspk/extract", "*.py")}
W0_BOOTSTRAP = ("lfspk/__init__.py", "lfspk/api.py", "lfspk/harness/__init__.py", "lfspk/harness/tmetrics.py",
                "lfspk/harness/align.py", "lfspk/harness/metrics.py")


# --- measurement ---------------------------------------------------------------------------

def ideal_of(d: dict, mel) -> tuple[np.ndarray, int]:
    import torch

    from lfspk.extract.api import valid_frames
    from lfspk.extract.frontend import ideal_log_mask

    n = len(d["audio"])
    m = valid_frames(n)
    absent = bool(d["info"]["absent"])
    y = d["noise"] if absent else d["target_image"] + d["noise"]
    with torch.no_grad():
        ideal = ideal_log_mask(mel(torch.from_numpy(np.ascontiguousarray(y, dtype=np.float32))[None]),
                               mel(torch.from_numpy(d["audio"])[None]))[0].numpy()[:, :m]
    return ideal, m


def metrics(net, d: dict, profile, ideal: np.ndarray, m: int) -> tuple[float, float, float]:
    """(id_under, under, over) of one render, monitor_reference.v3's arithmetic."""
    from lfspk.extract.harness_frontend import run_mask

    lm, _ = run_mask(net, d["audio"], profile)
    x = ideal - lm[:, :m]
    return (float(np.mean(ideal.astype(np.float64) ** 2)), float(np.mean(np.clip(-x, 0, None).astype(np.float64) ** 2)),
            float(np.mean(np.clip(x, 0, None).astype(np.float64) ** 2)))


# --- parity with W5's frozen screen table ----------------------------------------------------

def parity(out: Path = OUT, tol: float = 1e-9) -> dict:
    """V0-s0 and VB-s0 on W5's monitor set must reproduce screen_gate_table.json (frac S1-S4, over per family, S0 q99)."""
    from lfspk.extract.calibrate import load_set
    from lfspk.extract.frontend import parakeet_mel_power

    from .tune import base_path, load_base

    mel = parakeet_mel_power()
    table = json.loads((paths.RUNS / "W5" / "notes" / "screen_gate_table.json").read_text())
    nets = {v: load_base(base_path(f"{v}-s0"), f"{v}-s0")[0] for v in ("V0", "VB")}
    acc = {v: {} for v in nets}
    for _, d in load_set("monitor"):
        if d["info"]["absent"]:
            continue
        fam = d["info"]["family"]
        ideal, m = ideal_of(d, mel)
        for v, net in nets.items():
            acc[v].setdefault(fam, []).append(metrics(net, d, d["profile"], ideal, m))
    res = {"tol": tol, "runs": {}, "ok": True}
    for v in nets:
        a = {f: np.asarray(x) for f, x in acc[v].items()}
        got = {"frac_present": {f: float(1 - a[f][:, 1].mean() / a[f][:, 0].mean()) for f in ("S1", "S2", "S3", "S4")},
               "over_mean_present": {f: float(a[f][:, 2].mean()) for f in a},
               "S0_over_q99": float(np.quantile(a["S0"][:, 2], 0.99, method="higher"))}
        want = table["runs"][v]
        diffs = [abs(got["frac_present"][f] - want["frac_present"][f]) for f in got["frac_present"]]
        diffs += [abs(got["over_mean_present"][f] - want["over_mean_present"][f]) for f in want["over_mean_present"]]
        diffs.append(abs(got["S0_over_q99"] - want["S0_over_q99"]))
        res["runs"][v] = {"max_abs_diff": float(max(diffs)), "got": got}
        res["ok"] = bool(res["ok"] and max(diffs) <= tol)
    out.mkdir(parents=True, exist_ok=True)
    (out / "parity.json").write_text(json.dumps(res, indent=1, default=float))
    return res


# --- cells -----------------------------------------------------------------------------------

def cells(arm: str, a: str) -> list[tuple[str, tuple, tuple | None]]:
    """(cell, model_ref, profile_ref) for subject a and an arm."""
    b = S.control_donor(a)
    base, twin = S.ARMS[arm]
    out = [("base", ("base", base), ("p0", a)), ("twin", ("base", twin), None)]
    for st in STEPS:
        out.append((f"P{st}|personal", ("tuned", arm, "P", a, st), ("p0", a)))
        out.append((f"P{st}|control", ("tuned", arm, "P", b, st), ("p0", a)))
    out.append(("F1000|personal", ("tuned", arm, "F", a, 1000), ("p0", a)))
    out.append(("F1000|control", ("tuned", arm, "F", b, 1000), ("p0", a)))
    out.append(("P1000|swapA", ("tuned", arm, "P", a, 1000), ("p0", b)))
    out.append(("P1000|swapB", ("tuned", arm, "P", b, 1000), ("p0", b)))
    out.append(("P1000|drift", ("tuned", arm, "P", a, 1000), ("p_end", a)))
    return out


def tuned_path(arm: str, config: str, subject: str, step: int, tag: str = "", root: Path | None = None) -> Path:
    from .tune import OUT as TUNE_OUT

    leaf = subject if not tag else f"{subject}-{tag}"
    return (root or TUNE_OUT) / arm / config / leaf / f"step{step}.pt"


def score_keys(a: str) -> list[str]:
    from .render import expected_keys

    return [k for k in expected_keys("score") if k.split("-")[0] == a]


def involvement(a: str, info: dict) -> list[str]:
    inv = [a, S.control_donor(a)] + [str(s) for s in info.get("interferers", [])]
    if info.get("absent"):
        inv.append(str(info["talker"]))
    return list(dict.fromkeys(inv))


# --- provenance (code3-r1 M1, M2): every aggregated number is validated against the CURRENT inputs ---------------

def code_identity(repo: Path | None = None) -> dict:
    """Hashes of the whole calculation and reporting closure (CLOSURE, W0_BOOTSTRAP), relative to the repo root."""
    import hashlib

    repo = Path(repo or Path(__file__).resolve().parents[2])

    def files(paths_: list[Path]) -> str:
        h = hashlib.sha256()
        for q in sorted(paths_):
            h.update(f"{q.relative_to(repo)} {hashlib.sha256(q.read_bytes()).hexdigest()}\n".encode())
        return h.hexdigest()

    out = {f"{k}_closure_sha256": files(sorted((repo / d).glob(g))) for k, (d, g) in CLOSURE.items()}
    out["w0_bootstrap_sha256"] = files([repo / f for f in W0_BOOTSTRAP])
    return out


def current_state() -> dict:
    """The current inputs every score must name: scoring-set manifest, profile build and vectors, the dict
    manifest and bank pack the tunes must have used, the code closure and the base pins."""
    from .profiles import load as load_profiles
    from .profiles import vec_sha256
    from .render import validated_manifest
    from .signals import json_sha256
    from .stream import Bank

    profiles = load_profiles()  # verifies the profile file against its current identity
    pmeta = json.loads((paths.RUNS / "W6" / "profiles" / "profiles.json").read_text())
    dman = validated_manifest("dict", check_digests=False)
    bank = Bank(paths.RUNS / "W6" / "render" / "bank_pack")  # file hashes and the current bank render
    tin = {}
    for s in S.pilot_order():
        keys = [f"{s}-{j:02d}" for j in range(S.N_TUNE)]
        tin[s] = {"dict_identity_sha256": dman["identity_sha256"], "dict_digests": {k: dman["keys"][k] for k in keys},
                  "bank_pack_sha256": bank.pack_sha256, "profile_sha256": vec_sha256(profiles[s]["p0"]),
                  "profiles_identity_sha256": pmeta["identity_sha256"], "dict_manifest_sha256": json_sha256(dman)}
    from .tune import code_sha256 as tune_code_sha256
    from .tune import w5_code_sha256

    return {"score_manifest_sha256": json_sha256(validated_manifest("score", check_digests=False)),
            "profiles_identity_sha256": pmeta["identity_sha256"], "code": code_identity(), "bases": dict(S.BASES),
            "tune_code": {"w6_tune_code_sha256": tune_code_sha256(), "w5_code_sha256": w5_code_sha256()},
            "profiles": {s: {k: vec_sha256(v) for k, v in p.items()} for s, p in profiles.items()},
            "tuning_inputs": tin, "_profiles": profiles}


def model_record(ref: tuple, path_fn=tuned_path) -> dict:
    """What the model file at a reference currently is: sha256 and, for a readout, its identity fields."""
    import torch

    from lfspk.extract.harness_frontend import file_sha256

    from .tune import base_path, identity_sha256

    if ref[0] == "base":
        return {"kind": "base", "name": ref[1], "sha256": file_sha256(base_path(ref[1]))}
    _, arm, config, subject, step = ref[:5]
    p = path_fn(*ref[1:]) if len(ref) > 5 else path_fn(arm, config, subject, step)
    ck = torch.load(p, map_location="cpu", weights_only=True)
    ident = ck["identity"]
    c = ident["config"]
    return {"kind": "tuned", "path": str(p), "sha256": file_sha256(p), "identity_sha256": identity_sha256(ident),
            "step": int(ck["step"]), "arm": c["arm"], "config": c["config"], "subject": c["subject"], "tag": c["tag"],
            "device": c["device"], "platform": ident["runtime"]["platform"], "inputs": ident["inputs"],
            "base_sha256": ident["base_sha256"], "tune_config": c, "code": ident["code"], "alpha": ident["alpha"],
            "n_adapted": ident["n_adapted"]}


EXECUTION = {"": {"device": "cuda", "threads": 2}, "cpu": {"device": "cpu", "threads": 2},
             "mac": {"device": "cpu", "threads": 2}}  # registered execution settings per variant (DESIGN 4, 7)


def execution_key(tag: str) -> str:
    return "mac" if tag.startswith("mac-") else tag


def check_tuned(rec: dict, arm: str, config: str, subject: str, step: int, tag: str, current: dict,
                extra_inputs: tuple = ()) -> None:
    """A readout record must be the expected run (arm, configuration, subject, step, tag) with the registered
    hyperparameters (tune.PILOT_FIXED), the arm's alpha, the configuration's adapted count, the variant's registered
    execution settings and the current training code, tuned from the pinned base on exactly the current tuning inputs
    of its subject (plus `extra_inputs` keys, e.g. the Mac bundle's sha). Runtime versions and platform strings may
    differ between Mac and Linux; the platform prefix is checked per variant (check_variant)."""
    from .tune import EXPECTED_ALPHA, P_COUNT, PILOT_FIXED

    want = (arm, config, subject, step, tag)
    got = (rec["arm"], rec["config"], rec["subject"], rec["step"], rec["tag"])
    if got != want:
        raise RuntimeError(f"{rec['path']}: readout is {got}, expected {want}")
    c = rec["tune_config"]
    for k, v in PILOT_FIXED.items():
        cv = list(c[k]) if k == "readouts" else c[k]
        if cv != (list(v) if k == "readouts" else v):
            raise RuntimeError(f"{rec['path']}: {k} = {cv}, the pilot registers {v}")
    for k, v in EXECUTION[execution_key(tag)].items():
        if c[k] != v:
            raise RuntimeError(f"{rec['path']}: {k} = {c[k]}, the variant registers {v}")
    if rec["alpha"] != EXPECTED_ALPHA[arm]:
        raise RuntimeError(f"{rec['path']}: alpha {rec['alpha']} != {EXPECTED_ALPHA[arm]}")
    if config == "P" and rec["n_adapted"] != P_COUNT:
        raise RuntimeError(f"{rec['path']}: {rec['n_adapted']} adapted parameters, P registers {P_COUNT}")
    if rec["code"] != current["tune_code"]:
        raise RuntimeError(f"{rec['path']}: tuned with other training code")
    if rec["base_sha256"] != current["bases"][S.ARMS[arm][0]]:
        raise RuntimeError(f"{rec['path']}: tuned from an unpinned base")
    inputs = {k: v for k, v in rec["inputs"].items() if k not in extra_inputs}
    if inputs != current["tuning_inputs"][subject]:
        raise RuntimeError(f"{rec['path']}: tuned on inputs that differ from the current ones of {subject}")


def expected_records(a: str, current: dict, cache: dict, path_fn=tuned_path) -> dict:
    """{cell name: (current model record, expected profile digest)} for subject a, validated."""
    out = {}
    for arm in S.ARMS:
        for cell, mref, pref in cells(arm, a):
            if mref not in cache:
                cache[mref] = model_record(mref, path_fn)
            rec = cache[mref]
            if mref[0] == "base":
                if rec["sha256"] != current["bases"][mref[1]]:
                    raise RuntimeError(f"base {mref[1]} differs from its pin")
            else:
                check_tuned(rec, arm, mref[2], mref[3], mref[4], "", current)
            out[f"{arm}|{cell}"] = (rec, None if pref is None else current["profiles"][pref[1]][pref[0]])
    return out


def validate_meta(meta: dict, current: dict, expected: dict) -> None:
    """A subject's score record must name the current scoring set, profile build, code closure, every model's
    current file and identity, and every cell's current profile digest (code3-r1 M1)."""
    a = meta["subject"]
    if meta["score_manifest_sha256"] != current["score_manifest_sha256"]:
        raise RuntimeError(f"{a}: scores belong to another scoring set")
    if meta["profiles_identity_sha256"] != current["profiles_identity_sha256"]:
        raise RuntimeError(f"{a}: scored with another profile build")
    if meta["code"] != current["code"]:
        raise RuntimeError(f"{a}: scored with other code")
    if list(meta["cells"]) != list(expected):
        raise RuntimeError(f"{a}: cell list differs from the registered cells")
    for name, (rec, pdig) in expected.items():
        m = meta["models"][name]
        if m["sha256"] != rec["sha256"] or m.get("identity_sha256") != rec.get("identity_sha256"):
            raise RuntimeError(f"{a}/{name}: the model file differs from the one scored")
        if meta["profile_sha256"][name] != pdig:
            raise RuntimeError(f"{a}/{name}: scored with another profile than the current one")


def score_subject(args) -> str:
    """All cells of both arms for subject a -> scores/subjects/<a>.npy + .json."""
    a, out = args
    import torch

    from lfspk.extract.frontend import parakeet_mel_power

    from .render import load_set
    from .tune import load_base, load_tuned

    torch.set_num_threads(1)
    out = Path(out)
    current = current_state()
    profiles = current["_profiles"]
    mel = parakeet_mel_power()
    keys = score_keys(a)
    renders = [d for _, d in load_set("score", keys)]
    ideals = [ideal_of(d, mel) for d in renders]
    expected = expected_records(a, current, {})
    nets: dict = {}
    names, arr, provs, prof_digest = [], [], {}, {}
    for arm in S.ARMS:
        for cell, mref, pref in cells(arm, a):
            name = f"{arm}|{cell}"
            rec, pdig = expected[name]
            if mref not in nets:
                if mref[0] == "base":
                    from .tune import base_path

                    nets[mref], _, sha = load_base(base_path(mref[1]), mref[1])
                else:
                    nets[mref], _, sha = load_tuned(Path(rec["path"]))
                if sha != rec["sha256"]:
                    raise RuntimeError(f"{name}: model changed while scoring")
            prof = None if pref is None else profiles[pref[1]][pref[0]]
            names.append(name)
            provs[name] = rec
            prof_digest[name] = pdig
            arr.append([metrics(nets[mref], d, prof, *iv) for d, iv in zip(renders, ideals)])
    meta = {"subject": a, "keys": keys, "cells": names, "models": provs, "profile_sha256": prof_digest,
            "render_info": [{"family": d["info"]["family"], "absent": bool(d["info"]["absent"]),
                             "involved": involvement(a, d["info"])} for d in renders],
            "score_manifest_sha256": current["score_manifest_sha256"],
            "profiles_identity_sha256": current["profiles_identity_sha256"], "code": current["code"]}
    (out / "subjects").mkdir(parents=True, exist_ok=True)
    np.save(out / "subjects" / f"{a}.npy", np.asarray(arr, dtype=np.float64))  # [cells, renders, 3]
    (out / "subjects" / f"{a}.json").write_text(json.dumps(meta, indent=1))
    return a


def score_all(workers: int, out: Path = OUT) -> None:
    from multiprocessing import get_context

    from .render import validated_manifest

    validated_manifest("score")  # full digest check once
    with get_context("spawn").Pool(workers) as p:
        for a in p.imap_unordered(score_subject, [(s, str(out)) for s in S.pilot_order()]):
            print(json.dumps({"scored": a}), flush=True)


def load_scores(out: Path = OUT, current: dict | None = None) -> dict:
    """{"cells": {name: [n, 3]}, "subject", "family", "absent", "involved"} over all subjects, after validating every
    subject's record against the CURRENT inputs (validate_meta)."""
    current = current or current_state()
    cache: dict = {}
    cells_all, subj, fam, absent, inv = {}, [], [], [], []
    for a in S.pilot_order():
        meta = json.loads((out / "subjects" / f"{a}.json").read_text())
        if meta["subject"] != a or meta["keys"] != score_keys(a):
            raise RuntimeError(f"{a}: scores belong to another scoring set")
        validate_meta(meta, current, expected_records(a, current, cache))
        x = np.load(out / "subjects" / f"{a}.npy")
        if x.shape != (len(meta["cells"]), len(meta["keys"]), 3):
            raise RuntimeError(f"{a}: score array has the wrong shape")
        for i, n in enumerate(meta["cells"]):
            cells_all.setdefault(n, []).append(x[i])
        for r in meta["render_info"]:
            subj.append(a)
            fam.append(r["family"])
            absent.append(r["absent"])
            inv.append(r["involved"])
    return {"cells": {n: np.concatenate(v) for n, v in cells_all.items()}, "subject": np.asarray(subj),
            "family": np.asarray(fam), "absent": np.asarray(absent, bool), "involved": inv}


# --- D5 (code3-r1 M2) ---------------------------------------------------------------------------------------

def d5_variants(arm: str, a: str, mac_dir: Path) -> dict:
    """{variant: (path, tag, device, platform prefix, extra input keys)} of the expected D5 runs."""
    out = {"nixos": (tuned_path(arm, "P", a, 1000), "", "cuda", "Linux", ()),
           "cpu": (tuned_path(arm, "P", a, 1000, tag="cpu"), "cpu", "cpu", "Linux", ())}
    for rep in (1, 2):
        tag = f"mac-background-t2-r{rep}"
        out[f"mac-r{rep}"] = (Path(mac_dir) / arm / "P" / f"{a}-{tag}" / "step1000.pt", tag, "cpu", "macOS",
                              ("bundle_json_sha256",))
    return out


def check_variant(rec: dict, arm: str, a: str, variant: str, spec: tuple, current: dict) -> None:
    """The readout at a D5 path must be that variant's run: arm, subject, P, step 1,000, its tag, device and
    platform, on the subject's current tuning inputs (the Mac runs also name their bundle)."""
    _, tag, device, platform, extra = spec
    check_tuned(rec, arm, "P", a, 1000, tag, current, extra_inputs=extra)
    if rec["device"] != device or not str(rec["platform"]).startswith(platform):
        raise RuntimeError(f"{rec['path']}: {variant} must be tuned on {device}/{platform}, not "
                           f"{rec['device']}/{rec['platform']}")
    if extra and not all(k in rec["inputs"] for k in extra):
        raise RuntimeError(f"{rec['path']}: a Mac run must name its bundle")


def score_d5(mac_dir: Path, out: Path = OUT) -> dict:
    """D5 (DESIGN 7): the Mac-tuned (2 reps) and nixos-CPU models of the 2 measured subjects against the nixos CUDA
    model, on the subject's scoring set, pA. Every variant is checked to be the expected run (check_variant), and
    d5.json is bound to the scoring set, the profile build, the code and every variant's file."""
    import torch

    from lfspk.extract.frontend import parakeet_mel_power

    from .macbench import MAC_ARMS, MAC_SUBJECTS
    from .render import load_set
    from .tune import load_tuned

    torch.set_num_threads(1)
    current = current_state()
    profiles = current["_profiles"]
    mel = parakeet_mel_power()
    res, recs, errs = {}, {}, {}
    for a in MAC_SUBJECTS:
        keys = score_keys(a)
        renders = [d for _, d in load_set("score", keys)]
        ideals = [ideal_of(d, mel) for d in renders]
        for arm in MAC_ARMS:
            for v, spec in d5_variants(arm, a, mac_dir).items():
                key = f"{arm}|{a}|{v}"
                try:
                    rec = model_record(("tuned", arm, "P", a, 1000), path_fn=lambda *_, q=spec[0]: q)
                    check_variant(rec, arm, a, v, spec, current)
                except (FileNotFoundError, RuntimeError, KeyError) as e:
                    errs[key] = f"{type(e).__name__}: {e}"  # isolated to this variant (code3-r2 M4)
                    continue
                net, _, sha = load_tuned(spec[0])
                if sha != rec["sha256"]:
                    raise RuntimeError(f"{spec[0]} changed while scoring")
                arr = np.asarray([metrics(net, d, profiles[a]["p0"], *iv) for d, iv in zip(renders, ideals)])
                recs[key] = rec
                res[key] = {"sha256": sha, "metrics": arr.tolist(), "family": [d["info"]["family"] for d in renders],
                            "absent": [bool(d["info"]["absent"]) for d in renders]}
    prov = {"score_manifest_sha256": current["score_manifest_sha256"],
            "profiles_identity_sha256": current["profiles_identity_sha256"], "code": current["code"],
            "mac_dir": str(Path(mac_dir).resolve()), "variants": recs, "errors_at_scoring": errs}
    out.mkdir(parents=True, exist_ok=True)
    (out / "d5.json").write_text(json.dumps({"provenance": prov, "results": res}))
    return {k: v["sha256"] for k, v in res.items()}


def expected_rows(a: str) -> tuple[list[str], list[bool]]:
    """Family and absent flag of each of subject a's scoring renders, in scoring-key order."""
    keys = score_keys(a)
    return [k.split("-")[2] for k in keys], [k.split("-")[1] == "a" for k in keys]


def check_rows(key: str, result: dict) -> None:
    """A D5 result must hold one 3-metric row per scoring render of its subject, in key order (code3-r2 M3)."""
    a = key.split("|")[1]
    fam, absent = expected_rows(a)
    if not isinstance(result, dict):
        raise TypeError(f"d5.json: {key} is not a result object")
    m = np.asarray(result["metrics"], dtype=np.float64)
    if m.shape != (len(fam), 3) or not np.isfinite(m).all():
        raise RuntimeError(f"d5.json: {key} has metrics of shape {m.shape}, expected ({len(fam)}, 3)")
    if list(result["family"]) != fam or [bool(x) for x in result["absent"]] != absent:
        raise RuntimeError(f"d5.json: {key} rows are not the subject's scoring renders in order")


def validate_d5(d5: dict, current: dict, records: dict, errors: dict | None = None) -> dict:
    """{"results": per-variant results that are valid, "errors": per-variant reasons}.

    Global provenance (scoring set, profile build, code) failing raises: it invalidates every D5 number. Run-specific
    problems (a missing, substituted, replaced or truncated variant) are isolated to that variant (code3-r2 M4)."""
    p = d5["provenance"]
    if (p["score_manifest_sha256"], p["profiles_identity_sha256"], p["code"]) != (
            current["score_manifest_sha256"], current["profiles_identity_sha256"], current["code"]):
        raise RuntimeError("d5.json was scored against other inputs or code")
    errors = dict(errors or {})
    ok = {}
    for k, rec in records.items():
        try:
            r = p["variants"].get(k)
            res = d5["results"].get(k)
            if r is None or res is None:
                raise RuntimeError(f"d5.json lacks {k}")
            if (r["sha256"], r["identity_sha256"]) != (rec["sha256"], rec["identity_sha256"]) or res["sha256"] != rec["sha256"]:
                raise RuntimeError(f"d5.json: {k} differs from the current readout")
            check_rows(k, res)
            ok[k] = res
        except (RuntimeError, KeyError, ValueError, TypeError, IndexError) as e:  # per-result schema (code3-r3)
            errors[k] = f"{type(e).__name__}: {e}"
    return {"results": ok, "errors": errors}


def d5_records(mac_dir: Path, current: dict) -> tuple[dict, dict]:
    """(records, errors): the current record of every expected D5 run that is present and is its variant, and a
    reason for every one that is not. Nothing here fails the other runs."""
    from .macbench import MAC_ARMS, MAC_SUBJECTS

    recs, errors = {}, {}
    for a in MAC_SUBJECTS:
        for arm in MAC_ARMS:
            for v, spec in d5_variants(arm, a, mac_dir).items():
                key = f"{arm}|{a}|{v}"
                try:
                    rec = model_record(("tuned", arm, "P", a, 1000), path_fn=lambda *_, q=spec[0]: q)
                    check_variant(rec, arm, a, v, spec, current)
                    recs[key] = rec
                except (FileNotFoundError, RuntimeError, KeyError) as e:
                    errors[key] = f"{type(e).__name__}: {e}"
    return recs, errors


def load_d5(mac_dir: Path, current: dict, out: Path = OUT) -> dict:
    recs, errors = d5_records(mac_dir, current)
    return validate_d5(json.loads((out / "d5.json").read_text()), current, recs, errors)


def main(argv=None) -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("cmd", choices=("parity", "subjects", "d5"))
    ap.add_argument("--workers", type=int, default=4)
    ap.add_argument("--mac-dir", default=str(paths.RUNS / "W6" / "mac"))
    a = ap.parse_args(argv)
    if a.cmd == "parity":
        res = parity()
        print(json.dumps({"ok": res["ok"], **{v: r["max_abs_diff"] for v, r in res["runs"].items()}}))
        if not res["ok"]:
            raise SystemExit(1)
    elif a.cmd == "subjects":
        score_all(a.workers)
    else:
        print(json.dumps(score_d5(Path(a.mac_dir)), indent=1))


if __name__ == "__main__":
    main()
