"""Stage B of the front-end evaluator: transcripts with a stored mask, bypass
copies pinned to B, B*, and the load-time checks (DESIGN.md 14.2 fe-4, fe-5).

One cache per (stage A, weights, configuration):
`<out>/stageB/<weights>/<condition | bstar>/<config>/` with asr.jsonl,
asr.meta.json ({identity, identity_sha256, run}) and COMPLETE.json.

- Bypassed mixtures are never transcribed. Their entry is
  `cachepin.pin_bypass(B record, B identity, frozen audio hash)` plus
  `mask_sha256`, in one block flagged chunk -1.
- Masked mixtures, sorted by id, are cut into fixed chunks of CHUNK. Each
  chunk goes to `nemo_hook.transcribe_masked` (batch size BATCH, which
  length-sorts inside) and is written as one block. On resume, a chunk with
  fewer entries than its membership is removed and redone whole, so a resumed
  run batches exactly as an uninterrupted one.
- B* has no stage A: zero masks under C1 for every mixture of the set, and its
  own load branch.
"""

from __future__ import annotations

import hashlib
import io
import json
import os
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Callable

import numpy as np
import soundfile as sf

from ..extract import cachepin
from ..extract.api import InferenceConfig, MaskOutput, N_MELS, feature_frames
from ..extract.frontend import bypassed
from ..extract.nemo_hook import hook_code_sha256
from . import fe_registry as R
from . import fe_stage_a as A
from .forced import read_jsonl, truncate_incomplete_tail
from .frozen import FrozenSet
from .refs import ASR_DIR
from .util import audio_info

BATCH = 16
CHUNK = 256
BSTAR = "bstar"
BSTAR_STAGE_A = cachepin.identity_hash({"kind": "bstar"})
WEIGHTS = ("base", "m1")


def code_sha256() -> str:
    return hashlib.sha256(Path(__file__).read_bytes()).hexdigest()


def stage_b_dir(out: Path, weights: str, label: str, config: str) -> Path:
    return Path(out) / "stageB" / weights / label / config


def load_b(b_dir: Path) -> tuple[dict[str, dict[str, Any]], dict[str, Any]]:
    """B's records (keys mix:<id>, ...) and B's identity (asr.meta.json)."""
    b_dir = Path(b_dir)
    if not (b_dir / "asr.jsonl").exists() or not (b_dir / "asr.meta.json").exists():
        raise SystemExit(f"{b_dir}: B's cache (asr.jsonl, asr.meta.json) is required")
    return {r["key"]: r for r in read_jsonl(b_dir / "asr.jsonl")}, json.loads((b_dir / "asr.meta.json").read_text())


def frozen_mix_hashes(fs: FrozenSet) -> dict[str, str]:
    """`mix:<id>` -> the file SHA-256 in the set's CONTENT.sha256 (read-only)."""
    out = {}
    for line in (fs.root / "CONTENT.sha256").read_text().splitlines():
        sha, rel = line.split("  ", 1)
        if rel.startswith("mix/") and rel.endswith(".flac"):
            out["mix:" + rel[4:-5]] = sha
    return out


def require_base(weights: str) -> None:
    """Only `base` until a B_m1 cache and an m1 ASR identity exist (code2-r1 #1):
    an m1-labelled cache must never be built from, or checked against, base B."""
    if weights != "base":
        raise SystemExit(f"weights {weights!r} are not available: m1 needs its own B cache (B_m1) and ASR identity first")


def decode_verified(path: Path, want_sha256: str) -> np.ndarray:
    """Read the file's bytes once, require their SHA-256 to be the frozen set's,
    and decode exactly those bytes to float32. Only the frozen format is
    accepted (code12-r2 #2): frozen mixtures are 16 kHz mono by construction,
    so anything else is refused rather than resampled or downmixed as
    util.load_audio would; for 16 kHz mono files the samples equal
    util.load_audio's (tested)."""
    raw = Path(path).read_bytes()
    if hashlib.sha256(raw).hexdigest() != want_sha256:
        raise SystemExit(f"{path}: file bytes differ from the frozen set's hash")
    with sf.SoundFile(io.BytesIO(raw)) as f:
        if f.samplerate != 16000 or f.channels != 1:
            raise SystemExit(f"{path}: frozen mixtures must be 16 kHz mono, got {f.samplerate} Hz x {f.channels} channels")
        x = f.read(dtype="float32", always_2d=True)
    return np.ascontiguousarray(x[:, 0], dtype=np.float32)


def zero_mask(n: int) -> MaskOutput:
    t = feature_frames(n)
    return MaskOutput(np.zeros((N_MELS, t), np.float16), np.zeros(t, np.float32))


def _config(fe, name: str, stage_a: A.StageA | None) -> InferenceConfig:
    if stage_a is None:
        if name != "C1":
            raise SystemExit("B* runs under C1 only")
        return InferenceConfig("C1")
    cfg = fe.config(name)
    if cfg.bypass:
        th = stage_a.key["frontend_identity"].get("theta_b")
        if th is None or float(th) != float(cfg.theta_b):
            raise SystemExit(f"{name}: theta_b {cfg.theta_b} differs from stage A's identity ({th})")
    return cfg


def _identity(fs: FrozenSet, stage_a: A.StageA | None, cfg: InferenceConfig, asr_identity: dict, b_identity: dict,
              weights: str, batching: str, batch_size: int, chunk: int, registration_info: dict) -> dict[str, Any]:
    if weights not in WEIGHTS:
        raise SystemExit(f"weights must be one of {WEIGHTS}")
    try:
        base = cachepin.frontend_cache_identity(stage_a.key_sha256 if stage_a else BSTAR_STAGE_A, cfg.to_dict(), asr_identity,
                                                b_identity, hook_code_sha256(), batching, batch_size)
    except cachepin.StaleCache as e:
        raise SystemExit(str(e))
    return {**base, "set_id": fs.set_id, "set_hash": fs.hash, "condition": stage_a.key["condition"] if stage_a else BSTAR,
            "weights": weights, "chunk": int(chunk), "stage_b_code_sha256": code_sha256(), **registration_info}


def _registration_info(fs: FrozenSet, stage_a: A.StageA | None, exploratory: bool | None, sealed_apply: bool, repo: Path,
                       ledger: Path | None = None) -> dict:
    if stage_a is not None:
        k = stage_a.key
        return {"registration": k["registration"], "exploratory": k["exploratory"],
                "confirmatory_eligible": k["confirmatory_eligible"], "sealed_apply": k["sealed_apply"]}
    expl = bool(exploratory)
    reg = A._registration(fs, expl, sealed_apply, Path(repo), ledger)
    return {"registration": reg, "exploratory": expl, "confirmatory_eligible": bool(reg) and not expl,
            "sealed_apply": bool(sealed_apply)}


def _plan(fs: FrozenSet, stage_a: A.StageA | None, cfg: InferenceConfig) -> list[tuple[str, int, str, bool]]:
    """(mixture id, samples, mask hash, bypassed) in id order, decided from the
    stored u (F) or the zero mask (B*)."""
    rows = {r["id"]: r for r in fs.manifest}
    mids = sorted(stage_a.hashes) if stage_a else sorted(rows)
    out = []
    for m in mids:
        n = audio_info(fs.root / rows[m]["files"]["mix"])[1]
        if stage_a is None:
            z = zero_mask(n)
            out.append((m, n, A.array_sha256(z.log_mask, z.u), False))
            continue
        mo = A.read_mask(stage_a, m)
        out.append((m, n, stage_a.hashes[m], bypassed(mo, n, cfg)))
    return out


def _chunks(masked: list[str], chunk: int) -> dict[int, list[str]]:
    return {c: masked[i: i + chunk] for c, i in enumerate(range(0, len(masked), chunk))}


def run_stage_b(fs: FrozenSet, out: Path, *, stage_a: A.StageA | None, fe, config_name: str, model, asr_identity: dict,
                b_dir: Path | None = None, transcribe_fn: Callable | None = None, repo: Path = R.REPO, ledger: Path | None = None,
                exploratory: bool | None = None, sealed_apply: bool = False, weights: str = "base", chunk: int = CHUNK,
                batch_size: int = BATCH) -> Path:
    """Write (or resume) one stage-B cache. `stage_a=None` is B*. The default
    transcriber is nemo_hook.transcribe_masked; `model` is the loaded ASR model."""
    require_base(weights)
    if transcribe_fn is None:
        from ..extract.nemo_hook import transcribe_masked as transcribe_fn
    b_recs, b_ident = load_b(b_dir or ASR_DIR / fs.set_id)
    frozen = frozen_mix_hashes(fs)
    cfg = _config(fe, config_name, stage_a)
    info = _registration_info(fs, stage_a, exploratory, sealed_apply, Path(repo), Path(ledger) if ledger else A.LEDGER)
    ident = _identity(fs, stage_a, cfg, asr_identity, b_ident, weights, "batched", batch_size, chunk, info)
    ish = cachepin.identity_hash(ident)
    d = stage_b_dir(out, weights, ident["condition"], config_name)
    d.mkdir(parents=True, exist_ok=True)
    jl, meta_p, comp_p = d / "asr.jsonl", d / "asr.meta.json", d / "COMPLETE.json"
    if meta_p.exists():
        if json.loads(meta_p.read_text()).get("identity") != ident:
            raise SystemExit(f"{d}: holds stage B of another identity; use another --out")
    elif jl.exists() and jl.stat().st_size:
        raise SystemExit(f"{d}: holds transcripts without an identity")
    comp_p.unlink(missing_ok=True)
    run = R.run_event(Path(repo))
    meta_p.write_text(json.dumps({"identity": ident, "identity_sha256": ish, "run": run}, indent=1, sort_keys=True))
    ledger = Path(ledger) if ledger else A.LEDGER
    event = {"stage": "B", "set_id": fs.set_id, "set_hash": fs.hash, "condition": ident["condition"], "config": config_name,
             "weights": weights, "checkpoint_sha256": stage_a.key["frontend_identity"].get("checkpoint_sha256") if stage_a else None,
             "identity_sha256": ish, "exploratory": info["exploratory"], "registration": info["registration"], **run}
    R.append_ledger(ledger, {"event": "start", **event})  # before any transcription (code1-r1 #1)
    plan = _plan(fs, stage_a, cfg)
    by_id = {m: (n, h, byp) for m, n, h, byp in plan}
    masked = [m for m, _, _, byp in plan if not byp]
    chunks = _chunks(masked, chunk)
    member = {m: c for c, ms in chunks.items() for m in ms}
    # Resume: keep only verified entries of whole chunks (and individual bypass copies).
    have: dict[str, dict[str, Any]] = {}
    if jl.exists():
        truncate_incomplete_tail(jl)
        for e in read_jsonl(jl):
            m = e["key"][4:]
            if m not in by_id or e.get("audio_sha256") != frozen.get(e["key"]) or e.get("mask_sha256") != by_id[m][1] \
                    or bool(e.get("bypass")) != by_id[m][2] or (not e.get("bypass") and e.get("chunk") != member.get(m)):
                raise SystemExit(f"{d}: cached {e['key']} does not match the current inputs; refusing to resume")
            have[e["key"]] = e
    try:  # retained bypass copies must still equal the current B (code2-r1 #3)
        cachepin.verify_bypass({k: e for k, e in have.items() if e.get("bypass")}, b_recs, b_ident, frozen)
    except cachepin.StaleCache as e:
        raise SystemExit(f"{d}: refusing to resume: {e}")
    complete = {c for c, ms in chunks.items() if all(f"mix:{m}" in have for m in ms)}
    keep = [e for e in have.values() if e["bypass"] or e["chunk"] in complete]
    if len(keep) != len(have):
        tmp = jl.with_suffix(".tmp")
        tmp.write_text("".join(json.dumps(e) + "\n" for e in keep))
        os.replace(tmp, jl)
    have = {e["key"]: e for e in keep}
    rows = {r["id"]: r for r in fs.manifest}
    with open(jl, "a") as f:
        block = []
        for m, n, h, byp in plan:
            k = f"mix:{m}"
            if byp and k not in have:
                if k not in b_recs:
                    raise SystemExit(f"B's cache lacks {k}")
                try:
                    block.append({**cachepin.pin_bypass(b_recs[k], b_ident, frozen[k]), "mask_sha256": h, "chunk": -1})
                except cachepin.StaleCache as e:
                    raise SystemExit(str(e))
        if block:
            f.write("".join(json.dumps(e) + "\n" for e in block))
            f.flush()
        for c, ms in chunks.items():
            if c in complete:
                continue
            audios = [decode_verified(fs.root / rows[m]["files"]["mix"], frozen[f"mix:{m}"]) for m in ms]
            masks = [A.read_mask(stage_a, m) if stage_a else zero_mask(a.size) for m, a in zip(ms, audios)]
            for m, a in zip(ms, audios):
                if a.size != by_id[m][0]:
                    raise SystemExit(f"{m}: decoded length differs from the file header")
            res = transcribe_fn(model, audios, masks, cfg, batch_size)
            if len(res) != len(ms) or any(r is None for r in res):
                raise SystemExit(f"chunk {c}: a masked recording got no transcript")
            f.write("".join(json.dumps({"key": f"mix:{m}", "audio_sha256": frozen[f"mix:{m}"], "text": r["text"],
                                        "words": r["words"], "bypass": False, "mask_sha256": by_id[m][1], "chunk": c}) + "\n"
                            for m, r in zip(ms, res)))
            f.flush()
            print(json.dumps({"stage": "B", "chunk": c, "of": len(chunks), "n": len(ms)}), flush=True)
    keys = sorted(f"mix:{m}" for m in by_id)
    got = sorted(e["key"] for e in read_jsonl(jl))
    if got != keys:
        raise SystemExit(f"{d}: stage B wrote {len(got)} entries, expected {len(keys)}")
    n_byp = sum(1 for *_, b in plan if b)
    comp_p.write_text(json.dumps({"identity_sha256": ish, "n_keys": len(keys), "keys_sha256": hashlib.sha256("\n".join(keys).encode()).hexdigest(),
                                  "n_bypass": n_byp, "n_masked": len(keys) - n_byp}, indent=1))
    R.append_ledger(ledger, {"event": "complete", "stage": "B", "run_id": run["run_id"], "identity_sha256": ish,
                             "checkpoint_sha256": event["checkpoint_sha256"], "set_id": fs.set_id})
    return d


@dataclass(frozen=True)
class StageB:
    dir: Path
    identity: dict[str, Any]
    identity_sha256: str
    run: dict[str, Any]
    entries: dict[str, dict[str, Any]]
    n_bypass: int


def load_stage_b(fs: FrozenSet, out: Path, *, stage_a: A.StageA | None, fe, config_name: str, b_dir: Path | None = None,
                 repo: Path = R.REPO, weights: str = "base", chunk: int = CHUNK, exploratory: bool | None = None,
                 sealed_apply: bool | None = None, ledger: Path | None = None) -> StageB:
    """Load one stage-B cache with every check of DESIGN fe-5 (B*: its own
    branch). `stage_a` must come from `load_stage_a` (fresh validation). Any
    failure raises SystemExit; nothing is partially used."""
    require_base(weights)
    b_recs, b_ident = load_b(b_dir or ASR_DIR / fs.set_id)
    frozen = frozen_mix_hashes(fs)
    label = stage_a.key["condition"] if stage_a else BSTAR
    d = stage_b_dir(out, weights, label, config_name)
    meta_p, comp_p, jl = d / "asr.meta.json", d / "COMPLETE.json", d / "asr.jsonl"
    if not meta_p.exists():
        raise SystemExit(f"{d}: no stage B")
    meta = json.loads(meta_p.read_text())
    ident = meta.get("identity", {})
    try:
        cachepin.require_headline(ident)  # check 1: the `single` replay is refused
    except ValueError as e:
        raise SystemExit(f"{d}: {e}")
    cfg = _config(fe, config_name, stage_a)
    if stage_a is None:
        expl = bool(ident.get("exploratory")) if exploratory is None else exploratory
        sealed = bool(ident.get("sealed_apply")) if sealed_apply is None else sealed_apply
        info = _registration_info(fs, None, expl, sealed, Path(repo), ledger)
    else:
        info = _registration_info(fs, stage_a, None, False, Path(repo))
    # check 2 (and 3's binding to the freshly validated stage A): the identity recomputed from current inputs
    want = _identity(fs, stage_a, cfg, dict(b_ident), b_ident, weights, "batched", BATCH, chunk, info)
    if ident != want or meta.get("identity_sha256") != cachepin.identity_hash(want):
        diff = sorted(k for k in set(ident) | set(want) if ident.get(k) != want.get(k))
        raise SystemExit(f"{d}: stage B does not match the current expected identity (differs in {diff})")
    # check 4: coverage
    if not comp_p.exists():
        raise SystemExit(f"{d}: stage B did not complete")
    comp = json.loads(comp_p.read_text())
    rows = {r["id"]: r for r in fs.manifest}
    mids = sorted(stage_a.hashes) if stage_a else sorted(rows)
    keys = sorted(f"mix:{m}" for m in mids)
    lines = list(read_jsonl(jl))
    entries = {e["key"]: e for e in lines}
    if len(entries) != len(lines) or sorted(entries) != keys or comp.get("identity_sha256") != meta["identity_sha256"] \
            or comp.get("n_keys") != len(keys) or comp.get("keys_sha256") != hashlib.sha256("\n".join(keys).encode()).hexdigest():
        raise SystemExit(f"{d}: stage B does not cover exactly the expected {len(keys)} mixtures")
    # check 5: bypass copies against the current B
    try:
        cachepin.verify_bypass(entries, b_recs, b_ident, frozen)
    except cachepin.StaleCache as e:
        raise SystemExit(f"{d}: stale bypass copy: {e}")
    n_byp = 0
    for k, e in entries.items():
        m = k[4:]
        # check 6: frozen audio and the applied mask (B*: the zero mask of that length)
        if e.get("audio_sha256") != frozen.get(k):
            raise SystemExit(f"{d}: {k} was made from other audio than the frozen set's")
        if stage_a is None:
            if e.get("bypass"):
                raise SystemExit(f"{d}: B* holds a bypass entry ({k})")
            z = zero_mask(audio_info(fs.root / rows[m]["files"]["mix"])[1])
            if e.get("mask_sha256") != A.array_sha256(z.log_mask, z.u):
                raise SystemExit(f"{d}: B* entry {k} was not made with the zero mask")
            continue
        if e.get("mask_sha256") != stage_a.hashes[m]:
            raise SystemExit(f"{d}: {k} was made with another mask than stage A's")
        n_byp += bool(e.get("bypass"))
        # check 7: the bypass flag recomputed from the stored u, where present
        if not stage_a.purged:
            n = audio_info(fs.root / rows[m]["files"]["mix"])[1]
            with np.load(stage_a.dir / "masks" / f"{m}.npz") as z:
                mo = MaskOutput(z["log_mask"], z["u"])
            if bypassed(mo, n, cfg) != bool(e.get("bypass")):
                raise SystemExit(f"{d}: {k}'s bypass flag disagrees with the stored mask")
    if comp.get("n_bypass") != n_byp:
        raise SystemExit(f"{d}: COMPLETE's bypass count disagrees with the entries")
    return StageB(d, ident, meta["identity_sha256"], meta.get("run", {}), entries, n_byp)


def purge(fs: FrozenSet, out: Path, stage_a: A.StageA, fe, configs: list[str], b_dir: Path | None = None, repo: Path = R.REPO,
          weights: str = "base", chunk: int = CHUNK) -> None:
    """Delete a non-headline condition's arrays after its stage B is complete,
    and loads cleanly, for every configuration in use."""
    require_base(weights)
    if not configs:
        raise SystemExit("purge needs the configurations in use")
    for c in configs:
        load_stage_b(fs, out, stage_a=stage_a, fe=fe, config_name=c, b_dir=b_dir, repo=repo, weights=weights, chunk=chunk)
    A.purge_arrays(stage_a)


__all__ = ["BATCH", "CHUNK", "BSTAR", "BSTAR_STAGE_A", "code_sha256", "stage_b_dir", "load_b", "frozen_mix_hashes", "zero_mask",
           "run_stage_b", "StageB", "load_stage_b", "purge"]
