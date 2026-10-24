"""W6 render sets (DESIGN 2.2, 2.3, 2.4 audit references, 2.5), train split only.

    ./python -m lfspk.personal.render dict     --workers 4   # 22 subjects x up to 40 clean built-in dictations
    ./python -m lfspk.personal.render bank     --workers 6   # 1,000 public donor renders (200 per S0-S4), float16
    ./python -m lfspk.personal.render auditref --workers 6   # 200 W0 mixed-mode renders per S1-S4 (audit reference)
    ./python -m lfspk.personal.render score    --workers 6   # per-subject scoring sets (16 present per family, 4 absent)
    ./python -m lfspk.personal.render pack                   # bank -> one memory-mappable float16 file + index
    ./python -m lfspk.personal.render verify --set NAME      # validate a finished set against the CURRENT identity

Every set is bound to an identity (rules, subject lists and pools, W0's mixer
and index identity, W6 render code, W5 and W3 code), with a manifest of exact
keys and per-key array digests (W5's calibrate pattern). Consumers read only
through `load_set`, which validates the current identity, the keys and every
digest. Speaker audits run on every render:
- dictations: the subject's own enrollment-pool utterance, no interferer;
- bank and audit references: no held-out speaker in any role;
- scoring sets: the subject plus scoring-interferer speakers only (present),
  or scoring-interferer speakers only (absent); never another pilot subject.
"""

from __future__ import annotations

import argparse
import json
import os
import time
from pathlib import Path
from typing import Iterable

import numpy as np

from lfspk import paths

from . import subjects as S
from .signals import arrays_digest, db, json_sha256, pact

OUT = paths.RUNS / "W6" / "render"
FAMILIES = ("S0", "N", "S1", "S2", "S3", "S4")
SCEN = ("S0", "S1", "S2", "S3", "S4")
N_BANK = 200
N_AUDITREF = 200
N_SCORE_PRESENT = 16
N_SCORE_ABSENT = 4
N_GAIN_DB = (0.0, 15.0)
PEAK = 0.95

RULES = {
    "dict": {"utterances": "bank_utterances(partition) sorted by sha256('w6-enroll/<s>/<utt>')", "max": S.MAX_DICTATIONS,
             "tune": S.N_TUNE, "seed": "stable_int('w6-dict', s, utt) % 2**63", "scenario": "S0 (enrollment_dictation, clean)",
             "device": "builtin", "rir_mode": "coherent", "generator_pool": "train minus the 48 held-out"},
    "bank": {"families": list(SCEN), "n": N_BANK, "draw": "default_rng(stable_int('w6-bank', fam, i) % 2**63)",
             "targets": "target-eligible train-pool speakers, mixture pool 3-20 s", "device": "builtin",
             "rir_mode": "coherent", "dtype": "float16", "generator_pool": "train minus the 48 held-out"},
    "auditref": {"families": list(SCEN[1:]), "n": N_AUDITREF, "draw": "default_rng(stable_int('w6-auditref', fam, i) % 2**63)",
                 "targets": "target-eligible train-pool speakers, mixture pool 3-20 s", "device": "builtin",
                 "rir_mode": "mixed", "dtype": "float16", "generator_pool": "train minus the 48 held-out"},
    "score": {"present": N_SCORE_PRESENT, "absent": N_SCORE_ABSENT,
              "utterances": "mixture pool 3-20 s sorted by sha256('w6-score/<s>/<utt>')",
              "seed": "stable_int('w6-score', s, utt) % 2**63", "paired": list(SCEN), "device": "builtin",
              "rir_mode": "coherent", "N": "S1 member, interferers removed, noise x U[0, 15] dB "
                                          "(default_rng(stable_int('w6-score-n', s, i) % 2**63)), peak 0.95",
              "absent_draw": "default_rng(stable_int('w6-absent', s, fam, i) % 2**63) over target-eligible scoring "
                             "interferers", "generator_pool": "the 26 scoring interferers"},
}
RENDER_FILES = ("__init__.py", "subjects.py", "signals.py", "render.py")


# --- per-process context -----------------------------------------------------------------

_CTX: dict = {}


def _ctx() -> dict:
    if not _CTX:
        from lfspk.harness.mix import TARGET_SECONDS
        from lfspk.pvad.enrollment import librispeech_partitions

        held = S.held_out()
        _CTX.update(parts=librispeech_partitions("train"), held=held, scoring=S.scoring_interferers(held),
                    train_pool=S.train_pool(held), target_seconds=TARGET_SECONDS, gens={})
    return _CTX


def _gen(kind: str):
    """'train': the bank's pool (train minus held-out); 'score': the 26 scoring interferers."""
    c = _ctx()
    if kind not in c["gens"]:
        from lfspk.harness.mix import MixtureGenerator

        pool = c["train_pool"] if kind == "train" else list(c["scoring"])
        c["gens"][kind] = MixtureGenerator("train", speakers=pool)
    return c["gens"][kind]


def _by_id():
    return _gen("train").corpus.utterance_by_id


def mixture_pool(spk: str) -> list[str]:
    c = _ctx()
    lo, hi = c["target_seconds"]
    by = _by_id()
    return sorted(u for u in c["parts"][spk].mixture if lo <= by[u].seconds <= hi)


def dictation_utts(spk: str) -> list[str]:
    from lfspk.pvad.enrollment import bank_utterances

    import hashlib

    utts = bank_utterances(_ctx()["parts"][spk])
    return sorted(utts, key=lambda u: hashlib.sha256(f"w6-enroll/{spk}/{u}".encode()).hexdigest())


def score_utts(spk: str) -> list[str]:
    import hashlib

    pool = mixture_pool(spk)
    if len(pool) < N_SCORE_PRESENT:
        raise RuntimeError(f"{spk}: only {len(pool)} mixture-pool utterances")
    return sorted(pool, key=lambda u: hashlib.sha256(f"w6-score/{spk}/{u}".encode()).hexdigest())[:N_SCORE_PRESENT]


def _eligible(pool: Iterable[str]) -> list[str]:
    from lfspk.pvad.enrollment import target_eligible

    parts = _ctx()["parts"]
    return sorted((s for s in pool if target_eligible(parts[s]) and mixture_pool(s)), key=int)


_ELIG: dict = {}


def eligible(kind: str) -> list[str]:
    if kind not in _ELIG:
        c = _ctx()
        _ELIG[kind] = _eligible(c["train_pool"] if kind == "train" else c["scoring"])
    return _ELIG[kind]


def _stable(*keys) -> int:
    from lfspk.harness.util import stable_int

    return stable_int(*keys) % (2**63)


# --- keys ----------------------------------------------------------------------------------

def expected_keys(name: str) -> list[str]:
    if name == "dict":
        return [f"{s}-{j:02d}" for s in S.pilot_order() for j in range(len(dictation_utts(s)))]
    if name == "bank":
        return [f"{f}-{i:03d}" for f in SCEN for i in range(N_BANK)]
    if name == "auditref":
        return [f"{f}-{i:03d}" for f in SCEN[1:] for i in range(N_AUDITREF)]
    if name == "score":
        return ([f"{s}-p-{f}-{i:02d}" for s in S.pilot_order() for f in FAMILIES for i in range(N_SCORE_PRESENT)]
                + [f"{s}-a-{f}-{i:02d}" for s in S.pilot_order() for f in FAMILIES for i in range(N_SCORE_ABSENT)])
    raise ValueError(f"unknown set {name!r}")


# --- identity ------------------------------------------------------------------------------

def render_code_sha256() -> str:
    from lfspk.extract.train import files_sha256

    here = Path(__file__).resolve().parent
    return files_sha256([here / f for f in RENDER_FILES], here)


def set_identity(name: str) -> dict:
    from lfspk.extract.harness_frontend import code_sha256 as w5_code
    from lfspk.extract.train import w3_code_sha256
    from lfspk.pvad.identity import w0_identity

    c = _ctx()
    return json.loads(json.dumps({
        "kind": "w6-render", "set": name, "rules": RULES[name], "subjects_sha256": S.lists_sha256(),
        "held_out_sha256": json_sha256(sorted(c["held"], key=int)), "scoring_pool_sha256": json_sha256(list(c["scoring"])),
        "train_pool_sha256": json_sha256(sorted(c["train_pool"], key=int)), "w0": w0_identity("train"),
        "w6_render_code_sha256": render_code_sha256(), "w5_code_sha256": w5_code(), "w3_code_sha256": w3_code_sha256()}))


# --- audits --------------------------------------------------------------------------------

def _speakers(meta: dict) -> tuple[str, tuple[str, ...]]:
    from lfspk.pvad.w0_source import interferer_speakers

    return str(meta["target"]["speaker"]), tuple(interferer_speakers(meta))


def audit_dictation(meta: dict, spk: str, utt: str) -> None:
    tgt, others = _speakers(meta)
    if tgt != spk or meta["target"]["utt"] != utt:
        raise AssertionError("dictation render has another target")
    if others or meta.get("interferers"):
        raise AssertionError("a dictation render holds an interferer")
    if utt not in _ctx()["parts"][spk].enroll:
        raise AssertionError("dictation utterance outside the enrollment pool")


def audit_public(meta: dict, held: Iterable[str]) -> None:
    tgt, others = _speakers(meta)
    bad = ({tgt} | set(others)) & set(held)
    if bad:
        raise AssertionError(f"held-out speakers {sorted(bad)} in a public (bank/reference) render")


def audit_score(meta: dict, spk: str | None, scoring: Iterable[str], pilot: Iterable[str]) -> None:
    """spk = the subject for a present render, None for an absent one (target must be a scoring interferer)."""
    tgt, others = _speakers(meta)
    sc = set(scoring)
    if spk is not None:
        if tgt != spk:
            raise AssertionError("scoring render has another target")
        if spk in others:
            raise AssertionError("subject appears as its own interferer")
    elif tgt not in sc:
        raise AssertionError("absent-target talker is not a scoring interferer")
    if set(others) - sc:
        raise AssertionError(f"interferers {sorted(set(others) - sc)} outside the scoring pool")
    if (set(others) | ({tgt} if spk is None else set())) & set(pilot):
        raise AssertionError("another pilot subject appears in a scoring render")


# --- render jobs ---------------------------------------------------------------------------

def _save(path: Path, d: dict) -> None:
    tmp = path.with_name(path.stem + ".tmp.npz")
    np.savez(tmp, **d)
    os.replace(tmp, path)


def _f16(x) -> np.ndarray:
    return np.asarray(x, dtype=np.float32).astype(np.float16)


def check_dictation_activity(key: str, index: int, active_frames: int) -> None:
    """Tuning dictations (index < N_TUNE) must hold >= 50 target-active frames (the tuning stream places interference
    relative to them). Drift dictations (D3 only) are exempt: W1's gated update simply does not accept a dictation
    without usable speech windows (DESIGN erratum E1)."""
    from .signals import MIN_ACTIVE_FRAMES

    if index < S.N_TUNE and active_frames < MIN_ACTIVE_FRAMES:
        raise AssertionError(f"{key}: tuning dictation has fewer than {MIN_ACTIVE_FRAMES} target-active frames")


def dictation_scan() -> dict:
    """Pre-render check (erratum E1): every dictation's duration and W0 alignment activity (computed as W0's
    placed_activity does; equal to the rendered target_active on 708 of 708 quarantined renders), without rendering.
    Fails (AssertionError via check_dictation_activity) on any tuning dictation under 50 active frames."""
    from lfspk.api import FRAME_SAMPLES
    from lfspk.harness.mix import GAP_S, TARGET_SECONDS, activity_from_alignment

    corpus = _gen("train").corpus
    rows = []
    for spk in S.pilot_order():
        for j, u in enumerate(dictation_utts(spk)):
            ut = corpus.utterance_by_id[u]
            n = -(-ut.samples // FRAME_SAMPLES)
            act = int(activity_from_alignment(corpus.alignment(u), n * FRAME_SAMPLES, gap_s=GAP_S).sum())
            rows.append({"key": f"{spk}-{j:02d}", "utt": u, "seconds": ut.seconds, "active_frames": act,
                         "role": "tune" if j < S.N_TUNE else "drift"})
    return summarise_scan(rows, json_sha256(set_identity("dict")), TARGET_SECONDS)


def summarise_scan(rows: list[dict], set_sha256: str, target_seconds: tuple[float, float] = (3.0, 20.0)) -> dict:
    """The precheck's verdict over scan rows: raises on any tuning dictation under 50 active frames; records the dict
    set identity sha (the one the render binds to). `seconds` is the SOURCE utterance duration; the rendered
    recording is longer (W0 adds room-noise lead and tail)."""
    for r in rows:
        check_dictation_activity(r["key"], int(r["key"].rsplit("-", 1)[1]), r["active_frames"])
    lo, hi = target_seconds
    outside = [r for r in rows if not lo <= r["seconds"] <= hi]
    return {"n": len(rows), "tune_min_active_frames": min(r["active_frames"] for r in rows if r["role"] == "tune"),
            "drift_below_50_active": [r for r in rows if r["role"] == "drift" and r["active_frames"] < 50],
            "outside_3_20s_source": outside, "outside_3_20s_source_tune": [r for r in outside if r["role"] == "tune"],
            "set_identity_sha256": set_sha256, "rows": rows}


def _render_dict(key: str, out: Path) -> list[str]:
    from lfspk.extract.data import check_components

    spk, j = key.rsplit("-", 1)
    utt = dictation_utts(spk)[int(j)]
    seed = _stable("w6-dict", spk, utt)
    m = _gen("train").enrollment_dictation(utt, seed, device="builtin", contaminated=False)
    audit_dictation(m.meta, spk, utt)
    check_components(m)
    ta = np.asarray(m.target_active, dtype=bool)
    check_dictation_activity(key, int(j), int(ta.sum()))
    info = {"speaker": spk, "utt": utt, "seed": seed, "index": int(j), "role": "tune" if int(j) < S.N_TUNE else "drift",
            "meta": m.meta}
    _save(out / f"{key}.npz", {"audio": np.asarray(m.audio, np.float32), "target": np.asarray(m.target, np.float32),
                               "target_active": ta, "info": np.array(json.dumps(info))})
    return [key]


def _draw_public(tag: str, fam: str, i: int) -> tuple[str, str, int]:
    rng = np.random.default_rng(_stable(tag, fam, i))
    el = eligible("train")
    spk = el[int(rng.integers(len(el)))]
    pool = mixture_pool(spk)
    return spk, pool[int(rng.integers(len(pool)))], int(rng.integers(2**62))


def donor_stats(target, interf, noise, ta, ia) -> dict:
    """SIR_D and the noise-to-target ratio, from the float16-stored arrays (DESIGN 2.3)."""
    t, it, nz = (np.asarray(x, np.float32) for x in (target, interf, noise))
    pt = pact(t, ta)
    out = {"p_target_active": pt, "sir_db": None, "ntr": float(np.mean(nz.astype(np.float64) ** 2)) / pt if pt > 0 else None}
    if np.asarray(ia, bool).any():
        pi = pact(it, ia)
        out["sir_db"] = db(pt / pi) if pi > 0 else None
    return out


def _render_public(name: str, key: str, out: Path) -> list[str]:
    from lfspk.extract.data import check_components

    fam, i = key.split("-")
    tag = "w6-bank" if name == "bank" else "w6-auditref"
    mode = "coherent" if name == "bank" else "mixed"
    spk, utt, seed = _draw_public(tag, fam, int(i))
    m = _gen("train").render(fam, seed, target=utt, device="builtin", rir_mode=mode)
    if m.meta["target"]["utt"] != utt:
        raise AssertionError("W0 rendered another target")
    audit_public(m.meta, _ctx()["held"])
    check_components(m)
    interf = np.zeros_like(m.target)
    for x in m.interferers:
        interf = interf + x
    t16, i16, n16 = _f16(m.target), _f16(interf), _f16(m.noise)
    e16 = _f16(m.noise_parts.get("event", np.zeros_like(m.noise)))
    ta, ia = np.asarray(m.target_active, bool), np.asarray(m.interferer_active, bool)
    st = donor_stats(t16, i16, n16, ta, ia)
    _, others = _speakers(m.meta)
    info = {"family": fam, "index": int(i), "speaker": spk, "utt": utt, "seed": seed, "rir_mode": mode,
            "interferers": list(others), **st, "meta": m.meta}
    d = {"target": t16, "interf": i16, "target_active": ta, "interferer_active": ia, "info": np.array(json.dumps(info))}
    if name == "bank":
        d.update(noise=n16, event=e16)
    _save(out / f"{key}.npz", d)
    return [key]


def _n_variant(m, rng) -> tuple[np.ndarray, np.ndarray, np.ndarray, float]:
    """W5's N rule on an S1 render: interferers removed, noise x U[0, 15] dB, peak 0.95 (both scaled)."""
    g = np.float32(10.0 ** (float(rng.uniform(*N_GAIN_DB)) / 20.0))
    target, noise = np.asarray(m.target, np.float32), np.asarray(m.noise, np.float32) * g
    mix = target + noise
    peak = float(np.max(np.abs(mix), initial=0.0))
    if peak > PEAK:
        k = np.float32(PEAK / peak)
        target, noise = target * k, noise * k
        mix = target + noise
    return mix.astype(np.float32), target, noise, float(20 * np.log10(float(g)))


def _write_score(out: Path, key: str, audio, target_image, noise, interfering, info: dict) -> None:
    _save(out / f"{key}.npz", {"audio": np.asarray(audio, np.float32), "target_image": np.asarray(target_image, np.float32),
                               "noise": np.asarray(noise, np.float32), "interfering": np.asarray(interfering, bool),
                               "info": np.array(json.dumps(info))})


def _render_score_present(spk: str, i: int, out: Path) -> list[str]:
    from lfspk.extract.data import check_components
    from lfspk.pvad.enrollment import check_mixture_targets

    c = _ctx()
    utt = score_utts(spk)[i]
    seed = _stable("w6-score", spk, utt)
    check_mixture_targets(c["parts"][spk], [utt])
    group = _gen("score").render_paired(SCEN, seed, target=utt, device="builtin", rir_mode="coherent")
    keys = []
    for fam in SCEN:
        m = group[fam]
        if m.meta["target"]["utt"] != utt:
            raise AssertionError("W0 rendered another target")
        audit_score(m.meta, spk, c["scoring"], S.pilot_order())
        check_components(m)
        _, others = _speakers(m.meta)
        info = {"family": fam, "speaker": spk, "absent": False, "utt": utt, "seed": seed, "index": i,
                "interferers": list(others), "n_gain_db": None}
        key = f"{spk}-p-{fam}-{i:02d}"
        _write_score(out, key, m.audio, m.target, m.noise, m.interferer_active, info)
        keys.append(key)
        if fam == "S1":
            mix, target, noise, gdb = _n_variant(m, np.random.default_rng(_stable("w6-score-n", spk, i)))
            info = {**info, "family": "N", "interferers": [], "removed_interferers": list(others), "n_gain_db": gdb}
            key = f"{spk}-p-N-{i:02d}"
            _write_score(out, key, mix, target, noise, np.zeros(len(m.interferer_active), bool), info)
            keys.append(key)
    return keys


def _render_score_absent(spk: str, fam: str, i: int, out: Path) -> list[str]:
    from lfspk.extract.data import check_components

    c = _ctx()
    rng = np.random.default_rng(_stable("w6-absent", spk, fam, i))
    el = eligible("score")
    talker = el[int(rng.integers(len(el)))]
    pool = mixture_pool(talker)
    utt = pool[int(rng.integers(len(pool)))]
    seed = int(rng.integers(2**62))
    m = _gen("score").render("S1" if fam == "N" else fam, seed, target=utt, device="builtin", rir_mode="coherent")
    if m.meta["target"]["utt"] != utt:
        raise AssertionError("W0 rendered another target")
    audit_score(m.meta, None, c["scoring"], S.pilot_order())
    check_components(m)
    _, others = _speakers(m.meta)
    info = {"family": fam, "speaker": spk, "absent": True, "talker": talker, "utt": utt, "seed": seed, "index": i,
            "interferers": [] if fam == "N" else list(others), "n_gain_db": None}
    key = f"{spk}-a-{fam}-{i:02d}"
    ta, ia = np.asarray(m.target_active, bool), np.asarray(m.interferer_active, bool)
    if fam == "N":
        mix, target, noise, gdb = _n_variant(m, np.random.default_rng(_stable("w6-absent-n", spk, i)))
        info.update(n_gain_db=gdb, removed_interferers=list(others))
        _write_score(out, key, mix, target, noise, ta, info)
    else:
        _write_score(out, key, m.audio, m.target, m.noise, ta | ia, info)
    return [key]


def _job(args) -> list[str]:
    name, unit, out = args
    out = Path(out)
    if name == "dict":
        return _render_dict(unit, out)
    if name in ("bank", "auditref"):
        return _render_public(name, unit, out)
    if name == "score":
        parts = unit.split("-")
        if parts[1] == "p":
            return _render_score_present(parts[0], int(parts[2]), out)
        return _render_score_absent(parts[0], parts[2], int(parts[3]), out)
    raise ValueError(name)


def _units(name: str, todo: list[str]) -> list[str]:
    """Render units: one per key, except present scoring keys, which render as a paired group (spk, i)."""
    if name != "score":
        return todo
    units = []
    for k in todo:
        spk, kind, fam, i = k.split("-")
        u = f"{spk}-p-{int(i)}" if kind == "p" else f"{spk}-a-{fam}-{int(i)}"
        if u not in units:
            units.append(u)
    return units


# --- set lifecycle -------------------------------------------------------------------------

def render(name: str, workers: int, out: Path = OUT) -> None:
    from multiprocessing import get_context

    from lfspk.extract.stage0 import prepare_render_dir

    root = out / name
    keys = expected_keys(name)
    todo = prepare_render_dir(root, set_identity(name), keys)
    units = _units(name, todo)
    t0 = time.time()
    done = 0
    if units:
        with get_context("spawn").Pool(workers) as p:
            for got in p.imap_unordered(_job, [(name, u, str(root / "mix")) for u in units], chunksize=1):
                done += len(got)
                if done % 100 < len(got):
                    print(json.dumps({"set": name, "rendered": done, "of": len(todo),
                                      "elapsed_s": round(time.time() - t0, 1)}), flush=True)
    finish(name, out)


def finish(name: str, out: Path = OUT, keys: list[str] | None = None) -> dict:
    """Write the manifest, bound to the PERSISTED identity (W5 stepbudget-r2 #1)."""
    root = out / name
    keys = expected_keys(name) if keys is None else list(keys)
    have = sorted(p.stem for p in (root / "mix").glob("*.npz") if not p.stem.endswith(".tmp"))
    if have != sorted(keys):
        raise RuntimeError(f"{name}: renders do not match the expected keys")
    stored = json.loads((root / "render_identity.json").read_text())
    man = {"identity_sha256": json_sha256(stored), "keys": {k: arrays_digest(_npz(root / "mix" / f"{k}.npz")) for k in keys}}
    (root / "render.json").write_text(json.dumps(man, indent=1))
    return man


def _npz(path: Path) -> dict:
    z = np.load(path, allow_pickle=False)
    return {k: z[k] for k in z.files}


def decode(d: dict) -> dict:
    out = dict(d)
    out["info"] = json.loads(str(d["info"]))
    return out


def validated_manifest(name: str, out: Path = OUT, identity_fn=None, check_digests: bool = True,
                       keys: list[str] | None = None) -> dict:
    """The manifest, accepted only against the CURRENT identity, the exact keys and (optionally) every digest."""
    from lfspk.extract.identities import differing, same

    root = out / name
    stored = json.loads((root / "render_identity.json").read_text())
    current = (identity_fn or set_identity)(name)
    if not same(stored, current):
        raise RuntimeError(f"{name}: renders were made under another identity (differs in {differing(stored, current)})")
    man = json.loads((root / "render.json").read_text())
    if man["identity_sha256"] != json_sha256(stored):
        raise RuntimeError(f"{name}: manifest is bound to another identity")
    keys = expected_keys(name) if keys is None else list(keys)
    files = sorted(p.stem for p in (root / "mix").glob("*.npz"))
    if sorted(man["keys"]) != sorted(keys) or files != sorted(keys):
        raise RuntimeError(f"{name}: keys differ from the expected set")
    if check_digests:
        for k in keys:
            if arrays_digest(_npz(root / "mix" / f"{k}.npz")) != man["keys"][k]:
                raise RuntimeError(f"{name}/{k}: arrays differ from the manifest")
    return man


def load_set(name: str, keys: Iterable[str] | None = None, out: Path = OUT, identity_fn=None,
             expected: list[str] | None = None) -> Iterable[tuple[str, dict]]:
    """Yield (key, decoded arrays) after validating the set; each yielded file's digest is re-checked."""
    man = validated_manifest(name, out, identity_fn, check_digests=False, keys=expected)
    root = out / name
    for k in (sorted(man["keys"]) if keys is None else keys):
        if k not in man["keys"]:
            raise KeyError(k)
        d = _npz(root / "mix" / f"{k}.npz")
        if arrays_digest(d) != man["keys"][k]:
            raise RuntimeError(f"{name}/{k}: arrays differ from the manifest")
        yield k, decode(d)


# --- the packed bank (memory-mappable; DESIGN 2.3 and 7) ----------------------------------

PACK = "bank_pack"
CHANNELS = ("target", "interf", "noise", "event")


def pack(out: Path = OUT, identity_fn=None, keys: list[str] | None = None) -> dict:
    man = validated_manifest("bank", out, identity_fn, keys=keys)
    dst = out / PACK
    dst.mkdir(parents=True, exist_ok=True)
    keys = expected_keys("bank") if keys is None else list(keys)
    index, total, ftotal = [], 0, 0
    loaded = []
    for k in keys:
        d = decode(_npz(out / "bank" / "mix" / f"{k}.npz"))
        n, nf = len(d["target"]), len(d["target_active"])
        index.append({"key": k, "off": total, "n": n, "foff": ftotal, "nf": nf,
                      "info": {f: d["info"][f] for f in ("family", "index", "speaker", "utt", "seed", "interferers",
                                                         "sir_db", "ntr", "p_target_active")}})
        total, ftotal = total + n, ftotal + nf
        loaded.append(d)
    audio = np.lib.format.open_memmap(dst / "bank16.tmp.npy", mode="w+", dtype=np.float16, shape=(total, len(CHANNELS)))
    frames = np.zeros((ftotal, 2), dtype=bool)
    for e, d in zip(index, loaded):
        for c, name in enumerate(CHANNELS):
            audio[e["off"]: e["off"] + e["n"], c] = d[name]
        frames[e["foff"]: e["foff"] + e["nf"], 0] = d["target_active"]
        frames[e["foff"]: e["foff"] + e["nf"], 1] = d["interferer_active"]
    audio.flush()
    del audio
    os.replace(dst / "bank16.tmp.npy", dst / "bank16.npy")
    np.save(dst / "frames.npy", frames)
    (dst / "index.json").write_text(json.dumps(index))
    from lfspk.extract.harness_frontend import file_sha256

    meta = {"kind": "w6-bank-pack", "render_identity_sha256": man["identity_sha256"],
            "render_manifest_sha256": json_sha256(man), "channels": list(CHANNELS),
            "files": {f: file_sha256(dst / f) for f in ("bank16.npy", "frames.npy", "index.json")}}
    (dst / "pack.json").write_text(json.dumps(meta, indent=1))
    return meta


def main(argv=None) -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("cmd", choices=("dict", "bank", "auditref", "score", "pack", "verify", "precheck"))
    ap.add_argument("--workers", type=int, default=4)
    ap.add_argument("--set", default=None)
    a = ap.parse_args(argv)
    if a.cmd == "pack":
        print(json.dumps(pack(), indent=1))
    elif a.cmd == "precheck":
        S.verify_pilot()
        res = dictation_scan()
        OUT.mkdir(parents=True, exist_ok=True)
        (OUT / "dict_precheck.json").write_text(json.dumps(res, indent=1))
        print(json.dumps({k: v for k, v in res.items() if k != "rows"}, indent=1))
    elif a.cmd == "verify":
        man = validated_manifest(a.set)
        print(json.dumps({"set": a.set, "keys": len(man["keys"]), "identity_sha256": man["identity_sha256"]}))
    else:
        S.verify_pilot()
        render(a.cmd, a.workers)


if __name__ == "__main__":
    main()
