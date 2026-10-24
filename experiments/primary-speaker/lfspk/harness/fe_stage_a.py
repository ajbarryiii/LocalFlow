"""Stage A of the front-end evaluator (DESIGN.md 14.2 fe-3, fe-5 check 3).

    stage A = for each mixture of the set whose speaker's enrollment stream
              reaches k: profile = enroll(stream[:3]) then update(stream[3:k]);
              analyse(profile, mixture audio) -> {log_mask float16, u float32}

The code unit is this module alone; its SHA-256 is part of every stage-A key,
so edits to reports or metrics never invalidate stored masks. Layout:
`<root>/<checkpoint-sha12>/<set>/<device>-<clean|contaminated>-<k>/` with
IDENTITY.json ({key, key_sha256, run}), COMPLETE.json (per-key array hashes and
the torch thread counts the workers observed), masks/<mixture>.npz and, after
`purge_arrays`, PURGED.json. Only the headline condition keeps its arrays.
"""

from __future__ import annotations

import fcntl
import hashlib
import json
import os
from contextlib import contextmanager
from concurrent.futures import ProcessPoolExecutor
from dataclasses import dataclass
from multiprocessing import get_context
from pathlib import Path
from typing import Any

import numpy as np

from .. import paths
from ..api import check_audio
from ..extract.api import MaskOutput, check_mask_output
from ..extract.cachepin import identity_hash
from . import fe_registry as R
from .evaluate import DEVICES, KS, cond_key, expected_score_keys, load_factory
from .frozen import FrozenSet
from .util import load_audio

HEADLINE = ("builtin", False, 10)
ROOT = paths.RUNS / "W5" / "masks"
PROTOCOL = "enroll(stream[:3]) then update(stream[3:k]) in order; analyse(profile, util.load_audio(mix))"
KIND = "w0f-stage-a"


def slug(cond: tuple[str, bool, int]) -> str:
    device, contaminated, k = cond
    return f"{device}-{'contaminated' if contaminated else 'clean'}-{int(k)}"


def parse_slug(s: str) -> tuple[str, bool, int]:
    device, c, k = s.rsplit("-", 2)
    if device not in DEVICES or c not in ("clean", "contaminated") or int(k) not in KS:
        raise ValueError(f"not a condition: {s!r}")
    return device, c == "contaminated", int(k)


def stage_dir(root: Path, sha12: str, set_id: str, cond: tuple[str, bool, int]) -> Path:
    return Path(root) / sha12 / set_id / slug(cond)


def code_sha256() -> str:
    return hashlib.sha256(Path(__file__).read_bytes()).hexdigest()


def expected_mixtures(fs: FrozenSet, cond: tuple[str, bool, int]) -> list[str]:
    """Mixture ids of the whole set for which `cond` exists (the speaker's
    stream reaches k): `evaluate.expected_score_keys` restricted to `cond`."""
    pre = cond_key(*cond) + "|"
    return sorted(k[len(pre):] for k in expected_score_keys(fs, fs.manifest) if k.startswith(pre))


def array_sha256(log_mask: np.ndarray, u: np.ndarray) -> str:
    lm = np.ascontiguousarray(log_mask, dtype=np.float16)
    uu = np.ascontiguousarray(u, dtype=np.float32)
    h = hashlib.sha256()
    h.update(json.dumps({"log_mask": list(lm.shape), "u": list(uu.shape)}, sort_keys=True).encode())
    h.update(lm.tobytes())
    h.update(uu.tobytes())
    return h.hexdigest()


def sha12_of(fe_identity: dict[str, Any]) -> str:
    sha = fe_identity.get("checkpoint_sha256") or ""
    return sha[:12] if len(sha) >= 12 else identity_hash(fe_identity)[:12]


def _split(fs: FrozenSet) -> str:
    return fs.manifest[0]["meta"]["split"] if fs.manifest else "unknown"


def _registration(fs: FrozenSet, exploratory: bool, sealed_apply: bool, repo: Path, ledger: Path | None = None) -> dict | None:
    """The registration a stage-A/B artefact records. Dev sets need a valid
    committed registration unless the run is exploratory; sealed sets run only
    under the orchestrator's apply."""
    split = _split(fs)
    if split != "dev":
        if not sealed_apply:
            raise SystemExit(f"{fs.set_id} is a {split} set: front-end stages run on it only under the orchestrator's apply")
        return R.current_registration(repo, ledger)  # None only for the placeholder; malformed raises
    if exploratory:
        return None
    reg = R.current_registration(repo, ledger)
    if reg is None:
        raise SystemExit("no committed confirmatory-checkpoint registration (W5 RESULTS); register first or pass --exploratory")
    return reg


def make_key(fs: FrozenSet, spec: str, kwargs: dict[str, str], fe_identity: dict[str, Any], cond: tuple[str, bool, int],
             registration: dict | None, exploratory: bool, sealed_apply: bool, threads: int = 1) -> dict[str, Any]:
    eligible = bool(registration and not exploratory and fe_identity.get("run") == "R1" and fe_identity.get("seed") == 0
                    and fe_identity.get("checkpoint_sha256") == registration["sha256"])
    return {"kind": KIND, "frontend": spec, "args": dict(sorted(kwargs.items())), "frontend_identity": fe_identity,
            "frontend_identity_sha256": identity_hash(fe_identity), "set_id": fs.set_id, "set_hash": fs.hash,
            "condition": slug(cond), "protocol": PROTOCOL, "torch_threads": int(threads),
            "stage_a_code_sha256": code_sha256(), "registration": registration, "exploratory": bool(exploratory),
            "confirmatory_eligible": eligible, "sealed_apply": bool(sealed_apply)}


# --- workers --------------------------------------------------------------------------------

_FE = None


def _init_worker(spec: str, kwargs: dict[str, str]) -> None:
    global _FE
    import torch  # required: the thread count is observed, never assumed

    torch.set_num_threads(1)
    _FE = load_factory(spec)(**kwargs)


def _threads_now() -> int:
    import torch

    return int(torch.get_num_threads())


def check_declared_threads(fe_identity: dict[str, Any]) -> None:
    if fe_identity.get("analyse_threads") != 1:
        raise SystemExit("the front end must declare identity()['analyse_threads'] == 1 (one torch thread)")


def _analyse_speaker(args: tuple) -> dict[str, Any]:
    set_id, set_root, cond, speaker, mids, out = args
    fs = FrozenSet(set_id, root=Path(set_root))
    rows = {r["id"]: r for r in fs.manifest}
    device, contaminated, k = cond
    stream = fs.enrollment_stream(speaker, device, contaminated)
    if len(stream) < k:
        raise RuntimeError(f"speaker {speaker}: stream of {len(stream)} does not reach k = {k}")
    prof = _FE.enroll([check_audio(fs.audio(r["file"])) for r in stream[:3]])
    for r in stream[3:k]:
        prof = _FE.update(prof, check_audio(fs.audio(r["file"])))
    hashes, seen = {}, set()
    for mid in mids:
        audio = check_audio(load_audio(fs.root / rows[mid]["files"]["mix"]))
        mo = check_mask_output(_FE.analyse(prof, audio), audio.size)
        seen.add(_threads_now())
        lm, u = np.asarray(mo.log_mask).astype(np.float16), np.asarray(mo.u, dtype=np.float32)
        check_mask_output(MaskOutput(lm, u), audio.size)
        tmp = Path(out) / f".{mid}.tmp.npz"
        np.savez(tmp, log_mask=lm, u=u)
        os.replace(tmp, Path(out) / f"{mid}.npz")
        hashes[mid] = {"sha256": array_sha256(lm, u), "frames": int(u.size)}
    return {"hashes": hashes, "threads": sorted(seen)}


# --- run and load ------------------------------------------------------------------------------


def _other_live(base: Path, cond: tuple[str, bool, int]) -> list[str]:
    """Other non-headline conditions whose arrays exist on disk, whatever any
    marker says (a failed regeneration counts until it is cleaned up)."""
    out = []
    if base.is_dir():
        for d in sorted(p for p in base.iterdir() if p.is_dir()):
            if d.name in (slug(cond), slug(HEADLINE)):
                continue
            if any((d / "masks").glob("*.npz")) or any((d / "masks").glob(".*.tmp.npz")):
                out.append(d.name)
    return out


@contextmanager
def _locked(base: Path):
    """One stage-A writer (run, regeneration or purge) per front end and set at
    a time: an exclusive, non-blocking fcntl lock on base/.stage_a.lock."""
    base.mkdir(parents=True, exist_ok=True)
    with open(base / ".stage_a.lock", "a") as f:
        try:
            fcntl.flock(f, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise SystemExit(f"{base}: another stage-A run, regeneration or purge holds the lock")
        try:
            yield
        finally:
            fcntl.flock(f, fcntl.LOCK_UN)


def _clear_arrays(masks: Path) -> None:
    for p in list(masks.glob("*.npz")) + list(masks.glob(".*.tmp.npz")):
        p.unlink(missing_ok=True)


def run_stage_a(fs: FrozenSet, spec: str, kwargs: dict[str, str], cond: tuple[str, bool, int], workers: int = 8,
                root: Path = ROOT, exploratory: bool = False, repo: Path = R.REPO, ledger: Path | None = None,
                sealed_apply: bool = False, _sha_dir: str | None = None) -> Path:
    """Run stage A for one condition over every row of the set; returns its
    directory. `_sha_dir` exists for tests only."""
    registration = _registration(fs, exploratory, sealed_apply, Path(repo), Path(ledger) if ledger else LEDGER)
    fe = load_factory(spec)(**kwargs)
    fe_id = fe.identity()
    check_declared_threads(fe_id)
    key = make_key(fs, spec, kwargs, fe_id, cond, registration, exploratory, sealed_apply, 1)
    ksha = identity_hash(key)
    base = Path(root) / (_sha_dir or sha12_of(fe_id)) / fs.set_id
    with _locked(base):
        return _run_locked(fs, spec, kwargs, cond, workers, base, key, ksha, fe_id, registration, exploratory, Path(repo),
                           Path(ledger) if ledger else LEDGER)


LEDGER = paths.RUNS / "W0" / "frontend" / "LEDGER.jsonl"


def _run_locked(fs, spec, kwargs, cond, workers, base, key, ksha, fe_id, registration, exploratory, repo, ledger) -> Path:
    d = base / slug(cond)
    if tuple(cond) != HEADLINE:
        busy = _other_live(base, cond)
        if busy:
            raise SystemExit(f"non-headline conditions are processed one at a time; purge {busy} first")
    masks = d / "masks"
    ident_p, comp_p, purged_p = d / "IDENTITY.json", d / "COMPLETE.json", d / "PURGED.json"
    if ident_p.exists():
        if json.loads(ident_p.read_text())["key"] != key:
            raise SystemExit(f"{d}: holds stage A of another configuration; use another root")
    elif masks.exists() and any(masks.glob("*.npz")):
        raise SystemExit(f"{d}: holds masks without a verified identity")
    regenerate = purged_p.exists()
    old = json.loads(comp_p.read_text()) if regenerate else None
    if regenerate and (old is None or old.get("key_sha256") != ksha):
        raise SystemExit(f"{d}: purged arrays of another configuration")
    if not regenerate:
        comp_p.unlink(missing_ok=True)
    masks.mkdir(parents=True, exist_ok=True)
    run = R.run_event(repo)
    ident_p.write_text(json.dumps({"key": key, "key_sha256": ksha, "run": run}, indent=1, sort_keys=True))
    event = {"stage": "A", "set_id": fs.set_id, "set_hash": fs.hash, "condition": slug(cond),
             "checkpoint_sha256": fe_id.get("checkpoint_sha256"), "key_sha256": ksha, "exploratory": bool(exploratory),
             "registration": registration, "regenerated": regenerate, **run}
    # The start event precedes any analysis, so an interrupted run is still on record (code1-r1 #1).
    R.append_ledger(ledger, {"event": "start", **event})
    mids = expected_mixtures(fs, cond)
    rows = {r["id"]: r for r in fs.manifest}
    by_spk: dict[str, list[str]] = {}
    for m in mids:
        by_spk.setdefault(rows[m]["speaker"], []).append(m)
    jobs = [(fs.set_id, str(fs.root), tuple(cond), s, ms, str(masks)) for s, ms in sorted(by_spk.items(), key=lambda x: int(x[0]))]
    hashes: dict[str, Any] = {}
    seen: set[int] = set()
    try:
        with ProcessPoolExecutor(max(1, min(workers, len(jobs) or 1)), mp_context=get_context("spawn"),
                                 initializer=_init_worker, initargs=(spec, kwargs)) as ex:
            for res in ex.map(_analyse_speaker, jobs):
                hashes.update(res["hashes"])
                seen.update(res["threads"])
        if sorted(hashes) != mids:
            raise SystemExit(f"stage A produced {len(hashes)} arrays, expected {len(mids)}")
        if sorted(seen) != [1]:
            raise SystemExit(f"{d}: workers observed torch threads {sorted(seen)}, not one; refused")
        if regenerate and hashes != old["arrays"]:
            raise SystemExit(f"{d}: regenerated arrays differ from the recorded hashes; refused")
    except BaseException:
        if regenerate:
            _clear_arrays(masks)  # never leave arrays hidden behind PURGED.json
        raise
    if regenerate:
        purged_p.unlink()
    else:
        comp_p.write_text(json.dumps({"key_sha256": ksha, "n_keys": len(mids), "keys_sha256": hashlib.sha256("\n".join(mids).encode()).hexdigest(),
                                      "arrays": hashes, "observed_threads": sorted(seen)}, indent=1, sort_keys=True))
    R.append_ledger(ledger, {"event": "complete", "stage": "A", "run_id": run["run_id"], "key_sha256": ksha,
                             "checkpoint_sha256": fe_id.get("checkpoint_sha256"), "set_id": fs.set_id})
    return d


@dataclass(frozen=True)
class StageA:
    dir: Path
    key: dict[str, Any]
    key_sha256: str
    run: dict[str, Any]
    hashes: dict[str, str]  # mixture id -> array SHA-256
    purged: bool


def load_stage_a(fs: FrozenSet, spec: str, kwargs: dict[str, str], cond: tuple[str, bool, int], root: Path = ROOT,
                 exploratory: bool | None = None, repo: Path = R.REPO, fe=None, ledger: Path | None = None) -> StageA:
    """Validate a stage A fresh against the CURRENT expected key (front end
    rebuilt from spec and args, current code, current registration, one
    thread), its completeness and its coverage. Any failure raises SystemExit."""
    fe = fe or load_factory(spec)(**kwargs)
    fe_id = fe.identity()
    check_declared_threads(fe_id)
    d = stage_dir(root, sha12_of(fe_id), fs.set_id, cond)
    ident_p, comp_p = d / "IDENTITY.json", d / "COMPLETE.json"
    if not ident_p.exists():
        raise SystemExit(f"{d}: no stage A")
    ident = json.loads(ident_p.read_text())
    stored = ident.get("key", {})
    expl = bool(stored.get("exploratory")) if exploratory is None else bool(exploratory)
    sealed = bool(stored.get("sealed_apply"))
    want = make_key(fs, spec, kwargs, fe_id, cond, _registration(fs, expl, sealed, Path(repo), ledger), expl, sealed, 1)
    if stored != want or ident.get("key_sha256") != identity_hash(want):
        diff = sorted(k for k in set(stored) | set(want) if stored.get(k) != want.get(k))
        raise SystemExit(f"{d}: stage A does not match the current expected identity (differs in {diff})")
    if not comp_p.exists():
        raise SystemExit(f"{d}: stage A did not complete")
    comp = json.loads(comp_p.read_text())
    mids = expected_mixtures(fs, cond)
    if comp.get("key_sha256") != ident["key_sha256"]:
        raise SystemExit(f"{d}: COMPLETE belongs to another stage A")
    if sorted(comp.get("arrays", {})) != mids or comp.get("n_keys") != len(mids):
        raise SystemExit(f"{d}: stage A does not cover the expected {len(mids)} mixtures")
    if comp.get("observed_threads") != [1]:
        raise SystemExit(f"{d}: workers observed torch threads {comp.get('observed_threads')}, not one")
    purged = (d / "PURGED.json").exists()
    if purged and (any((d / "masks").glob("*.npz")) or any((d / "masks").glob(".*.tmp.npz"))):
        raise SystemExit(f"{d}: arrays present although marked purged (an unfinished regeneration?)")
    if not purged:
        missing = [m for m in mids if not (d / "masks" / f"{m}.npz").exists()]
        if missing:
            raise SystemExit(f"{d}: {len(missing)} arrays missing although not purged")
    return StageA(d, stored, ident["key_sha256"], ident.get("run", {}), {m: v["sha256"] for m, v in comp["arrays"].items()}, purged)


def read_mask(st: StageA, mid: str) -> MaskOutput:
    """The stored arrays of one mixture, verified against their recorded hash."""
    if st.purged:
        raise SystemExit(f"{st.dir}: arrays were purged; regenerate stage A first")
    with np.load(st.dir / "masks" / f"{mid}.npz") as z:
        lm, u = z["log_mask"], z["u"]
    if lm.dtype != np.float16 or u.dtype != np.float32 or array_sha256(lm, u) != st.hashes[mid]:
        raise SystemExit(f"{st.dir}: {mid} differs from its recorded hash")
    return MaskOutput(lm, u)


def purge_arrays(st: StageA) -> None:
    """Delete a non-headline condition's arrays, keeping IDENTITY, COMPLETE
    (with the per-key hashes) and a PURGED marker. The stage-B completeness
    precondition is checked by the evaluator's `purge` command."""
    if st.key["condition"] == slug(HEADLINE):
        raise SystemExit("the headline condition's arrays are kept persistently")
    with _locked(st.dir.parent):
        (st.dir / "PURGED.json").write_text(json.dumps({"key_sha256": st.key_sha256, "n_keys": len(st.hashes)}, indent=1))
        _clear_arrays(st.dir / "masks")


__all__ = ["HEADLINE", "ROOT", "slug", "parse_slug", "stage_dir", "code_sha256", "expected_mixtures", "array_sha256",
           "sha12_of", "make_key", "run_stage_a", "StageA", "load_stage_a", "read_mask", "purge_arrays"]
