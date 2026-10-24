"""Conditioning profiles (DESIGN 5): p0 from the 10 tuning dictations and the drift profile.

    ./python -m lfspk.personal.profiles build --workers 4

p0(s) = W1 `enroll(<the 10 tuning dictations' audio>).directions[0]`, with W5's
fixed profile path (`harness_frontend.W1_DEFAULTS`: redimnet2-b2, robust, raw,
score head, 1.5 s windows, 0.25 s hop, C 1.0, cache 0) on CPU, one torch thread.
p_end(s) = the same profile after `update` with each remaining dictation in
order (up to 30; diagnostic D3 only). Output runs/W6/profiles/profiles.npz and
profiles.json (identity: W1 settings, W1 code and artifact hashes, embedder
weights, the dictation set's manifest, and the sha256 of each profile's
float32 bytes).
"""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path

import numpy as np

from lfspk import paths

from . import subjects as S
from .signals import json_sha256

OUT = paths.RUNS / "W6" / "profiles"
PROFILE_FILES = ("profiles.py",)


def vec_sha256(v: np.ndarray) -> str:
    return hashlib.sha256(np.ascontiguousarray(v, dtype=np.float32).tobytes()).hexdigest()


def w1_settings() -> dict:
    from lfspk.extract.harness_frontend import W1_DEFAULTS

    return dict(W1_DEFAULTS, cache="0")


def w1_identity(root: Path | None = None) -> dict:
    from lfspk.extract.harness_frontend import w1_artifact_sha256s, w1_code_sha256

    st = w1_settings()
    root = (root or paths.RUNS / "W1").resolve()
    args = {k: st[k] for k in ("embedder", "norm", "rule", "head", "window", "hop", "C")}
    return {"settings": st, "w1_artifact_sha256": w1_artifact_sha256s(**args, root=root), "w1_code_sha256": w1_code_sha256(),
            "w1_runs_root": str(root)}


def make_profiler(root: Path | None = None):
    """W1's factory exactly as `harness_frontend.make` builds it (artifact hashes checked before and after)."""
    from lfspk.embed.factory import make as w1_make

    root = (root or paths.RUNS / "W1").resolve()
    before = w1_identity(root)
    prof = w1_make(device="cpu", runs=str(root), **w1_settings())
    if w1_identity(root) != before:
        raise RuntimeError("W1 artifacts changed while the profile path was being built")
    return prof


def direction(profile) -> np.ndarray:
    e = np.asarray(profile.directions[0], dtype=np.float32)
    if e.shape != (192,) or not np.isfinite(e).all() or abs(float(np.linalg.norm(e)) - 1.0) > 1e-4:
        raise ValueError("profile direction is not a finite unit 192-vector")
    return e


def enroll_window_counts(prof, audios) -> tuple[object, list[dict]]:
    """W1's enroll, computed through its own enroll_windows (identical result), plus per-dictation window counts:
    windows kept by the speech gate and, for the robust/anchored rules, windows kept by robust trimming."""
    from lfspk.api import check_audio
    from lfspk.embed.scorer import embed_windows, robust_keep

    wins = [embed_windows(prof.embedder, check_audio(a), prof.config.update_window) for a in audios]
    p = prof.enroll_windows(wins)
    sizes = [int(w.emb.shape[0]) for w in wins]
    kept = list(sizes)
    if prof.config.update.rule in ("robust", "anchored") and sum(sizes):
        keep = robust_keep(np.concatenate([w.emb for w in wins]), prof.config.update.trim_mads)
        offs = np.cumsum([0] + sizes)
        kept = [int(keep[offs[i]:offs[i + 1]].sum()) for i in range(len(sizes))]
    rows = [{"seconds_rendered": len(a) / 16000.0, "windows_layout": int(w.n_layout),
             "windows_speech": n, "windows_kept": k} for a, w, n, k in zip(audios, wins, sizes, kept)]
    return p, rows


def check_enroll_equivalence(spk: str, via_windows, via_enroll) -> None:
    """p0 is built through enroll_windows (for the window counts); the reviewed path is prof.enroll. Their serialized
    profiles must be bit-identical, else the job fails (orchestrator condition, 2026-10-24)."""
    if via_windows.to_bytes() != via_enroll.to_bytes():
        raise RuntimeError(f"{spk}: enroll_windows and enroll give different profiles")


def check_tuning_windows(spk: str, rows: list[dict], accepted: int) -> None:
    """Every tuning dictation must contribute >= 1 window to p0 (erratum E1, code review E1-r1 m1)."""
    bad = [i for i, r in enumerate(rows) if r["windows_kept"] < 1]
    if bad or accepted != len(rows):
        raise RuntimeError(f"{spk}: tuning dictations {bad} contribute no window to p0 (accepted {accepted}/{len(rows)})")


def subject_profiles(spk: str) -> dict:
    import torch

    from .render import load_set

    torch.set_num_threads(1)
    prof = make_profiler()
    keys = [k for k in _dict_keys() if k.rsplit("-", 1)[0] == spk]
    audios = [d["audio"] for _, d in load_set("dict", keys)]
    if len(audios) < S.N_TUNE:
        raise RuntimeError(f"{spk}: fewer than {S.N_TUNE} dictations")
    p, tune_rows = enroll_window_counts(prof, audios[: S.N_TUNE])
    check_enroll_equivalence(spk, p, prof.enroll(audios[: S.N_TUNE]))  # the reviewed path must give the same profile
    check_tuning_windows(spk, tune_rows, int(p.accepted))
    p0 = direction(p)
    drift_rows = []
    for a in audios[S.N_TUNE:]:
        before = int(p.accepted)
        p = prof.update(p, a)
        drift_rows.append({"seconds_rendered": len(a) / 16000.0, "accepted": int(p.accepted) > before})
    pend = direction(p)
    weights = getattr(getattr(prof, "embedder", None), "weights_sha256", None)
    return {"speaker": spk, "p0": p0, "p_end": pend, "n_updates": len(audios) - S.N_TUNE,
            "cos_p0_pend": float(np.dot(p0, pend)), "embedder_weights_sha256": weights,
            "tune_windows": tune_rows, "drift": drift_rows, "drift_accepted": sum(r["accepted"] for r in drift_rows)}


def _dict_keys() -> list[str]:
    from .render import expected_keys

    return expected_keys("dict")


def identity() -> dict:
    from lfspk.extract.train import files_sha256

    from .render import validated_manifest

    here = Path(__file__).resolve().parent
    man = validated_manifest("dict", check_digests=False)
    return json.loads(json.dumps({"kind": "w6-profiles", "w1": w1_identity(), "dict_manifest_sha256": json_sha256(man),
                                  "subjects_sha256": S.lists_sha256(), "n_tune": S.N_TUNE, "torch_threads": 1,
                                  "w6_profile_code_sha256": files_sha256([here / f for f in PROFILE_FILES], here)}))


def build(workers: int, out: Path = OUT) -> dict:
    from multiprocessing import get_context

    from .render import validated_manifest

    validated_manifest("dict")  # full digest check once, before any embedding
    ident = identity()
    out.mkdir(parents=True, exist_ok=True)
    if (out / "profiles.json").exists():
        raise FileExistsError(f"{out}/profiles.json exists; profiles are written once")
    with get_context("spawn").Pool(workers) as p:
        res = p.map(subject_profiles, list(S.pilot_order()))
    w = {r["embedder_weights_sha256"] for r in res}
    if len(w) != 1:
        raise RuntimeError("embedder weights differ across workers")
    subs = [r["speaker"] for r in res]
    p0 = np.stack([r["p0"] for r in res])
    pend = np.stack([r["p_end"] for r in res])
    np.savez(out / "profiles.npz", subjects=np.array(subs), p0=p0, p_end=pend)
    from lfspk.extract.harness_frontend import file_sha256

    meta = {"identity": ident, "identity_sha256": json_sha256(ident), "embedder_weights_sha256": w.pop(),
            "npz_sha256": file_sha256(out / "profiles.npz"),
            "subjects": {r["speaker"]: {"p0_sha256": vec_sha256(r["p0"]), "p_end_sha256": vec_sha256(r["p_end"]),
                                        "n_updates": r["n_updates"], "cos_p0_pend": r["cos_p0_pend"],
                                        "tune_windows": r["tune_windows"], "drift": r["drift"],
                                        "drift_accepted": r["drift_accepted"]} for r in res},
            "tune_windows_kept_min": min(x["windows_kept"] for r in res for x in r["tune_windows"]),
            "enroll_equivalence": True}  # every subject passed check_enroll_equivalence (a failure aborts the job)
    (out / "profiles.json").write_text(json.dumps(meta, indent=1))
    return meta


def load(out: Path = OUT, verify_current: bool = True) -> dict[str, dict[str, np.ndarray]]:
    """{speaker: {"p0", "p_end"}} after checking the file hash, every vector digest and (on nixos) the current identity."""
    from lfspk.extract.harness_frontend import file_sha256
    from lfspk.extract.identities import differing, same

    meta = json.loads((out / "profiles.json").read_text())
    if file_sha256(out / "profiles.npz") != meta["npz_sha256"]:
        raise RuntimeError("profiles.npz differs from profiles.json")
    if verify_current and not same(meta["identity"], identity()):
        raise RuntimeError(f"profiles were built under another identity (differs in {differing(meta['identity'], identity())})")
    z = np.load(out / "profiles.npz", allow_pickle=False)
    res = {}
    for i, s in enumerate(map(str, z["subjects"])):
        p0, pe = z["p0"][i].astype(np.float32), z["p_end"][i].astype(np.float32)
        if vec_sha256(p0) != meta["subjects"][s]["p0_sha256"] or vec_sha256(pe) != meta["subjects"][s]["p_end_sha256"]:
            raise RuntimeError(f"{s}: profile digest mismatch")
        res[s] = {"p0": p0, "p_end": pe}
    if sorted(res) != sorted(S.pilot_order()):
        raise RuntimeError("profiles cover another subject set")
    return res


def main(argv=None) -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("cmd", choices=("build",))
    ap.add_argument("--workers", type=int, default=4)
    a = ap.parse_args(argv)
    print(json.dumps(build(a.workers), indent=1))


if __name__ == "__main__":
    main()
