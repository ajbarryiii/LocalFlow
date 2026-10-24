"""Stage C: profile growth, contamination, poisoning and genuine change
(DESIGN.md, Stage C).

  ./python[-nemo] -m lfspk.embed.adapt embed --split dev|train --embedders A B .. [--device cuda]
  ./python -m lfspk.embed.adapt calibrate --embedder A [--norm asnorm]
  ./python -m lfspk.embed.adapt simulate --embedder A [--norm asnorm] [--n-boot 1000]
(add --smoke to run from uncommitted code; such output is not a result)

Dictations come from W0's harness (`lfspk.harness.mix.MixtureGenerator`): each
speaker's `speaker_plan` enrollment stream (30 dictations, in order), rendered
clean (S0-like) with the built-in microphone colouring, again with the
headset colouring, and contaminated (S4-like, built-in) at the plan's
contaminated positions (one in five); on dev also the plan's 10 test targets
rendered as S0 with each colouring. Train uses fit-half speakers only
(`protocol.cohort_role`). Window embeddings (scorer windowing) are computed
once per dictation and cached; the update rules run on cached windows
(`EmbeddingScorer.enroll_windows` / `update_windows`, identical to `enroll` /
`update` on audio).

`embed` writes RUNS/W1/adapt/<split>/<embedder>/{emb.f32.npy, index.json};
the index keeps, per dictation, its LibriVox project and chapter, the plan's
session relation, and the identities of contaminating speakers.

`calibrate` (train, fit half) writes gates_<norm>.json, bound to the
embedder, norm, window and min_kept it was computed for: window gate = score
reached by 10 % of same-sex impostor windows; dictation gate = threshold at
which 1 % of all same-sex impostor dictations pass the complete acceptance
rule (`scorer.accepts`, the updater's own decision); anchor gate = raw cosine
to the enrollment anchor reached by 1 % of same-sex impostor dictations; drift
floor = 1st percentile over speakers of the lowest cosine between a clean
gated profile and its anchor along a CALIBRATION_HORIZON-dictation stream
(the 27 cached updates cycled; the longest horizon available on train).
Achieved own and impostor pass rates of the complete rules are reported.

`simulate` (dev) runs every rule x condition and writes results/<embedder>_<norm>.json.
"""

from __future__ import annotations

import argparse
import json
import os
import time
from dataclasses import dataclass, replace
from pathlib import Path

import numpy as np

from .. import paths
from . import metrics as M
from . import protocol as P
from .profile import EmbProfile
from .scorer import (UPDATE_WINDOW, Cohort, EmbeddingScorer, ScorerConfig, UpdateConfig, Windows, accepts,
                     dictation_statistic, embed_windows)
from .survey import require_clean

OUT = Path(os.environ.get("LFSPK_W1_ADAPT_OUT", paths.RUNS / "W1" / "adapt"))  # override for smoke runs
WINDOW = UPDATE_WINDOW  # Stage C windows = the scorer's update windows (and the evaluation windows)
DEVICES = ("builtin", "headset")
SET_SEED = 0
SNAPSHOTS = (3, 10, 30)
POISON_FRACTIONS = (0.3, 0.5)
MATURE = 300  # clean dictations before long-horizon poisoning or change starts
LONG_HORIZON = 600
LONG_FRACTIONS = (0.1, 0.3, 0.5)
BURST = 20
LONG_SNAPSHOTS = (30, 300, 320, 400, 600)
ACCEPT_BLOCK = 50  # genuine acceptance rate is reported per block of this many dictations
EVAL_STRIDE = 6  # held-out target windows used for evaluation: every 6th (non-overlapping 1.5 s at hop 0.25)
CALIBRATION_HORIZON = 300
RULES = ("naive", "gated", "robust", "anchored")
TRAIN_SPEAKERS = 160  # calibration speakers: every k-th fit-half train speaker by id
HEADLINE_EXCLUDES = ("same_chapter",)  # contract: same-chapter speakers are reported separately
SESSION_MIN = 15  # session change: distinct dictations needed in each of two projects
SESSION_CAP = 40  # at most this many rendered per project
CHANGE_BLOCK = 50  # acceptance before (last block before MATURE) vs after (last block of the horizon)


def _gen(split):
    from ..harness.mix import MixtureGenerator

    return MixtureGenerator(split)


def split_speakers(split: str) -> list[str]:
    spk = sorted(_gen(split).corpus.speakers, key=int)
    if split == "train":
        spk = [s for s in spk if P.cohort_role(s) == "fit"]
        spk = spk[:: max(1, len(spk) // TRAIN_SPEAKERS)][:TRAIN_SPEAKERS]
    elif split != "dev":
        raise PermissionError("dev or train only")
    return spk


def _contaminators(meta: dict) -> list[str]:
    out = set()
    for i in meta.get("interferers", []):
        for key in ("speaker", "speakers"):
            v = i.get(key)
            if isinstance(v, (list, tuple)):
                out.update(str(x) for x in v)
            elif v is not None:
                out.add(str(v))
    return sorted(out)


def _dictations(split: str, speakers: list[str]):
    """Yield (record, Mixture) for every dictation needed."""
    from ..harness.util import stable_int

    gen = _gen(split)
    for spk in speakers:
        plan = gen.speaker_plan(spk)
        for j, u in enumerate(plan.enrollment):
            seed = stable_int("enroll", split, SET_SEED, spk, j) % (2**63)
            base = {"speaker": spk, "j": j, "relation": plan.relations[j], "plan_flags": list(plan.flags),
                    "chapter": u.chapter, "project": gen.corpus.project(u)}
            yield dict(base, key=f"{spk}/enroll/{j}", kind="enroll"), gen.enrollment_dictation(u, seed, "builtin")
            yield dict(base, key=f"{spk}/enroll_hs/{j}", kind="enroll_hs"), gen.enrollment_dictation(u, seed, "headset")
            if j in plan.contaminated_positions:
                m = gen.enrollment_dictation(u, seed, "builtin", True)
                yield dict(base, key=f"{spk}/dirty/{j}", kind="dirty", contaminators=_contaminators(m.meta)), m
        if split == "dev":
            for proj, utts in session_pools(gen, plan).items():
                for j, u in enumerate(utts):
                    seed = stable_int("w1-session", split, spk, proj, u.id) % (2**63)
                    yield ({"speaker": spk, "j": j, "key": f"{spk}/session/{proj}/{j}", "kind": "session",
                            "project": proj, "chapter": u.chapter, "utt": u.id},
                           gen.enrollment_dictation(u, seed, "builtin"))
            for j, u in enumerate(plan.targets):
                seed = stable_int("w1-target", split, spk, j) % (2**63)
                for dev, kind in (("builtin", "target"), ("headset", "target_hs")):
                    yield ({"speaker": spk, "j": j, "key": f"{spk}/{kind}/{j}", "kind": kind},
                           gen.render("S0", seed, target=u, device=dev))


def session_pools(gen, plan) -> dict[str, list]:
    """Per LibriVox project, the speaker's utterances usable as session-change
    dictations: 2-20 s, outside the plan's test chapter (so never the test
    session), sorted by id, at most SESSION_CAP. Returned only when at least
    two projects have SESSION_MIN or more; otherwise empty (the speaker does
    not qualify)."""
    pools: dict[str, list] = {}
    for u in gen.corpus.utterances[plan.speaker]:
        if u.chapter != plan.test_chapter and 2.0 <= u.seconds <= 20.0:
            pools.setdefault(gen.corpus.project(u), []).append(u)
    pools = {p: sorted(v, key=lambda u: u.id)[:SESSION_CAP] for p, v in pools.items() if len(v) >= SESSION_MIN}
    return pools if len(pools) >= 2 else {}


def cmd_embed(args) -> None:
    paths.require_mount()
    commit = require_clean(args.smoke)
    from .embedder import load_embedder

    if args.device.startswith("cuda"):
        import torch

        torch.cuda.set_per_process_memory_fraction(float(os.environ["AGENT_JOBS_VRAM_FRACTION"]))
    models = [load_embedder(n, args.device) for n in args.embedders]
    rows = {m.name: [] for m in models}
    index = {m.name: [] for m in models}
    count = {m.name: 0 for m in models}
    index_hashes: dict = {}
    t0 = time.time()
    for rec, mix in _dictations(args.split, split_speakers(args.split)[: args.limit]):
        h = mix.meta.get("index_hashes", {})
        if index_hashes and h != index_hashes:
            raise RuntimeError("W0 index/alignment hashes changed during extraction")
        index_hashes = h
        for m in models:
            w = embed_windows(m, mix.audio, WINDOW)
            index[m.name].append(dict(rec, row=count[m.name], n=len(w.spans), n_layout=w.n_layout, spans=w.spans,
                                      seconds=round(mix.audio.size / 16000, 3)))
            rows[m.name].append(w.emb)
            count[m.name] += len(w.spans)
    for m in models:
        d = OUT / args.split / m.name
        d.mkdir(parents=True, exist_ok=True)
        np.save(d / "emb.f32.npy", np.concatenate(rows[m.name]).astype(np.float32))
        meta = {"embedder": m.name, "weights_sha256": m.weights_sha256, "window": WINDOW.__dict__, "git": commit,
                "smoke": args.smoke, "split": args.split, "set_seed": SET_SEED, "w0_index_hashes": index_hashes,
                "seconds": round(time.time() - t0, 1), "dictations": index[m.name]}
        (d / "index.json").write_text(json.dumps(meta))
        print(m.name, len(index[m.name]), "dictations", count[m.name], "windows", flush=True)


@dataclass
class Cache:
    emb: np.ndarray
    by_key: dict[str, dict]
    window: dict
    provenance: dict = None  # {"git", "smoke"} of the run that built the cache

    @classmethod
    def load(cls, split: str, embedder: str, smoke: bool | None = None) -> "Cache":
        """Load and validate a cache. With `smoke` given (the consuming run's
        flag), a smoke cache is refused for a real run."""
        d = OUT / split / embedder
        meta = json.loads((d / "index.json").read_text())
        prov = {"git": meta.get("git", "unknown"), "smoke": bool(meta.get("smoke", True))}
        cache = cls(np.load(d / "emb.f32.npy"), {r["key"]: r for r in meta["dictations"]}, meta["window"], prov)
        if cache.window != WINDOW.__dict__:
            raise ValueError(f"{d}: cache window {cache.window} != {WINDOW.__dict__}")
        check_upstream(prov, smoke, str(d))
        return cache

    def windows(self, key: str) -> Windows:
        r = self.by_key[key]
        return Windows([tuple(s) for s in r["spans"]], self.emb[r["row"]: r["row"] + r["n"]],
                       np.zeros(0), np.zeros(0, bool), r["n_layout"])

    def speakers(self) -> list[str]:
        return sorted({r["speaker"] for r in self.by_key.values()}, key=int)

    def stream(self, spk: str, dirty: bool = False, device: str = "builtin") -> list[str]:
        kind = "enroll" if device == "builtin" else "enroll_hs"
        keys = sorted((r for r in self.by_key.values() if r["speaker"] == spk and r["kind"] == kind),
                      key=lambda r: r["j"])
        out = []
        for r in keys:
            dk = f"{spk}/dirty/{r['j']}"
            out.append(dk if dirty and dk in self.by_key else r["key"])
        return out

    def relation(self, spk: str, k: int) -> str:
        """The weakest session relation among the speaker's first k (at most
        30) enrollment dictations, as in W0's SpeakerPlan.relation_at."""
        order = ("cross_project", "same_project_cross_chapter", "same_chapter")
        rel = [self.by_key[x]["relation"] for x in self.stream(spk)[:k]]
        return max(rel, key=order.index) if rel else order[0]


def check_upstream(prov: dict, smoke: bool | None, what: str) -> None:
    """A real (non-smoke) run may consume only real, committed upstream artefacts."""
    if smoke is False and (prov.get("smoke", True) or str(prov.get("git", "unknown")).endswith(("-dirty", "unknown"))):
        raise RuntimeError(f"{what} comes from a smoke or uncommitted run ({prov}); rebuild it or pass --smoke")


class _NoModel:
    """Stand-in embedder: simulations never embed audio; windows come from the cache."""

    def __init__(self, name: str):
        self.name, self.dim, self.params = name, 0, 0


def gates_path(embedder: str, norm: str, root: Path | None = None) -> Path:
    return (root or OUT) / "train" / embedder / f"gates_{norm}.json"


def load_gates(embedder: str, norm: str, smoke: bool | None = None, root: Path | None = None) -> dict:
    """Gates from `root` (default OUT): validated against embedder, norm,
    window and min_kept, and, for a real run (smoke=False), refused unless
    they come from a real committed calibration."""
    path = gates_path(embedder, norm, root)
    g = json.loads(path.read_text())
    check_upstream({"git": g.get("git", "unknown"), "smoke": g.get("smoke", True)}, smoke, str(path))
    want = {"embedder": embedder, "norm": norm, "window": WINDOW.__dict__, "min_kept": UpdateConfig().min_kept}
    got = {k: g.get(k) for k in want}
    if got != want:
        raise ValueError(f"gates {path} were calibrated for {got}, not {want}")
    return g


def make_scorer(embedder: str, rule: str, gates: dict | None, norm: str = "asnorm",
                survey_root: Path | None = None) -> EmbeddingScorer:
    upd = UpdateConfig(rule=rule)
    if gates and rule != "naive":
        upd = replace(upd, window_gate=gates["window_gate"], dictation_gate=gates["dictation_gate"])
        if rule == "anchored":
            upd = replace(upd, anchor_gate=gates["anchor_gate"], drift_floor=gates["drift_floor"])
    cfg = ScorerConfig(embedder, WINDOW, norm=norm, update=upd, name=f"w1-{embedder}-{rule}", update_window=WINDOW)
    cohort = Cohort.from_survey(embedder, WINDOW.window_s, survey_root) if norm == "asnorm" else None
    return EmbeddingScorer(cfg, embedder=_NoModel(embedder), cohort=cohort)  # type: ignore[arg-type]


def sex_of(split: str) -> dict[str, str]:
    return _gen(split).corpus.sex


def _unit(x):
    return x / np.linalg.norm(x)


def complete_rule_gate(statistics: np.ndarray, target_rate: float) -> float:
    """Smallest gate g such that at most floor(target_rate * N) of the N
    statistics satisfy (finite and >= g); -inf statistics (dictations the
    min_kept condition rejects) never pass. Computed in float64, as
    `scorer.accepts` compares."""
    x = np.asarray(statistics, np.float64)
    finite = np.sort(x[np.isfinite(x)])
    allowed = int(np.floor(target_rate * x.size))
    if finite.size <= allowed:
        return -np.inf
    return float(np.nextafter(finite[finite.size - allowed - 1], np.inf))


def cmd_calibrate(args) -> None:
    commit = require_clean(args.smoke)
    cache = Cache.load("train", args.embedder, args.smoke)  # validates the window and provenance
    sc = make_scorer(args.embedder, "robust", None, args.norm, args.survey_root)
    sex = sex_of("train")
    spk = [s for s in cache.speakers() if P.cohort_role(s) == "fit"]
    min_kept = sc.config.update.min_kept
    rng = np.random.default_rng(11)
    own_w, imp_w, own_d, imp_d = [], [], [], []
    for a in spk:
        stream = cache.stream(a)
        if len(stream) < 10:
            continue
        prof = sc.enroll_windows([cache.windows(k) for k in stream[:3]])
        anchor = prof.directions[0].astype(np.float64)
        others = [b for b in spk if b != a and sex[b] == sex[a] and len(cache.stream(b)) >= 10]
        b = others[int(rng.integers(len(others)))]
        for k, bucket_w, bucket_d in ([(k, own_w, own_d) for k in stream[3:10]] +
                                      [(k, imp_w, imp_d) for k in cache.stream(b)[3:10]]):
            w = cache.windows(k)
            s = sc.window_scores(prof, w.emb, kind="update")[0]
            bucket_w.append(s)
            cos = float(_unit(w.emb.mean(axis=0).astype(np.float64)) @ anchor) if w.emb.shape[0] else -np.inf
            bucket_d.append((s, cos))
    imp_all = np.concatenate(imp_w)
    window_gate = float(np.quantile(imp_all, 0.90))
    imp_stat = np.array([dictation_statistic(s, window_gate, min_kept) for s, _ in imp_d])
    dictation_gate = complete_rule_gate(imp_stat, 0.01)
    imp_anchor = np.array([c for _, c in imp_d])
    anchor_gate = complete_rule_gate(imp_anchor, 0.01)
    cfg = UpdateConfig(rule="gated", window_gate=window_gate, dictation_gate=dictation_gate, min_kept=min_kept)
    gated = make_scorer(args.embedder, "gated", {"window_gate": window_gate, "dictation_gate": dictation_gate},
                        args.norm, args.survey_root)
    lows = []
    for a in spk:
        stream = cache.stream(a)
        if len(stream) < 10:
            continue
        stream = _long(stream, CALIBRATION_HORIZON, f"{a}/calibration")
        prof = gated.enroll_windows([cache.windows(k) for k in stream[:3]])
        anchor, low = prof.directions[0], 1.0
        for k in stream[3:]:
            prof = gated.update_windows(prof, cache.windows(k))
            low = min(low, float(prof.directions[0] @ anchor))
        lows.append(low)
    drift_floor = float(np.quantile(lows, 0.01))
    gates = {"embedder": args.embedder, "norm": args.norm, "window": WINDOW.__dict__, "min_kept": min_kept,
             "window_gate": window_gate, "dictation_gate": dictation_gate, "anchor_gate": anchor_gate,
             "drift_floor": drift_floor, "drift_horizon": CALIBRATION_HORIZON, "git": commit,
             "smoke": args.smoke or cache.provenance["smoke"], "cache": cache.provenance,
             "n_train_speakers": len(spk),
             "achieved": {  # through the updater's own decision (`accepts`)
                 "impostor_window_pass": float((imp_all >= window_gate).mean()),
                 "own_window_pass": float((np.concatenate(own_w) >= window_gate).mean()),
                 "impostor_dictation_pass": float(np.mean([accepts(s, cfg) for s, _ in imp_d])),
                 "own_dictation_pass": float(np.mean([accepts(s, cfg) for s, _ in own_d])),
                 "impostor_anchor_pass": float(np.mean([np.isfinite(c) and c >= anchor_gate for _, c in imp_d])),
                 "own_anchor_pass": float(np.mean([np.isfinite(c) and c >= anchor_gate for _, c in own_d])),
                 "own_drift_low_median": float(np.median(lows))}}
    gates_path(args.embedder, args.norm).write_text(json.dumps(gates, indent=1))
    print(json.dumps(gates))


# ------------------------------------------------------------------ streams

def _rng(*keys) -> np.random.Generator:
    from ..harness.util import stable_int

    return np.random.default_rng(stable_int(*keys) % (2**32))


def _cycled(updates: list[str], n: int, seed_key: str) -> list[str]:
    """n update dictations: fresh seeded permutations of `updates`, concatenated.
    Long horizons repeat cached dictations (no new acoustic variation); they
    exercise the update dynamics, not session variability."""
    rng, out = _rng("w1-cycle", seed_key), []
    while len(out) < n:
        out += [updates[i] for i in rng.permutation(len(updates))]
    return out[:n]


def _poisoned(stream_a: list[str], stream_b: list[str], frac: float, seed_key: str, start: int = 3) -> list[str]:
    """Replace round(frac * (len - start)) dictations at positions >= start by
    B's update dictations (B's positions 3.., in B's order, cycled), at
    seeded positions."""
    n_upd = len(stream_a) - start
    pos = sorted(start + _rng("w1-poison", seed_key).choice(n_upd, size=int(round(frac * n_upd)), replace=False))
    b_upd = stream_b[3:]
    out = list(stream_a)
    for i, p in enumerate(pos):
        out[p] = b_upd[i % len(b_upd)]
    return out


def _long(stream: list[str], horizon: int, seed_key: str) -> list[str]:
    return list(stream[:3]) + _cycled(stream[3:], horizon - 3, seed_key)


def spouse_of(a: str, speakers: list[str], sex: dict[str, str], half: dict[str, str], same_sex: bool) -> str:
    from ..harness.util import stable_int

    pool = [b for b in speakers if b != a and half.get(b) == half.get(a) and (sex[b] == sex[a]) == same_sex]
    if not pool:  # only in tiny smoke runs; the 73-speaker dev always has a same-half partner
        pool = [b for b in speakers if b != a and (sex[b] == sex[a]) == same_sex]
    return pool[stable_int("w1-spouse", a, same_sex) % len(pool)]


def conditions() -> dict[str, dict]:
    """Every simulated condition. `base` names the condition it is paired
    with; `same_sex` marks conditions in which a second speaker's dictations
    enter the stream; `targets` the colouring of the held-out targets."""
    out: dict[str, dict] = {"clean": {"snaps": SNAPSHOTS},
                            "contaminated20": {"dirty": True, "snaps": SNAPSHOTS, "base": "clean"}}
    for f in POISON_FRACTIONS:
        for same in (True, False):
            out[f"poison{int(f * 100)}_{'samesex' if same else 'crosssex'}"] = {
                "poison": f, "same_sex": same, "snaps": SNAPSHOTS, "base": "clean"}
    out["long_clean"] = {"horizon": LONG_HORIZON, "snaps": LONG_SNAPSHOTS}
    for f in LONG_FRACTIONS:
        out[f"long_mature_poison{int(f * 100)}_samesex"] = {
            "horizon": LONG_HORIZON, "poison": f, "same_sex": True, "poison_start": MATURE,
            "snaps": LONG_SNAPSHOTS, "base": "long_clean"}
    out["long_mature_burst20_samesex"] = {"horizon": LONG_HORIZON, "burst": BURST, "same_sex": True,
                                          "snaps": LONG_SNAPSHOTS, "base": "long_clean"}
    # Genuine change after a mature profile (no second speaker).
    out["long_session_control"] = {"horizon": LONG_HORIZON, "session": "control", "snaps": LONG_SNAPSHOTS}
    out["long_session_change"] = {"horizon": LONG_HORIZON, "session": "change", "snaps": LONG_SNAPSHOTS,
                                  "base": "long_session_control", "change": True}
    out["long_device_change"] = {"horizon": LONG_HORIZON, "device_change": True, "snaps": LONG_SNAPSHOTS,
                                 "base": "long_clean", "targets": "headset", "change": True}
    return out


def session_split(cache: Cache, a: str) -> tuple[list[str], list[str]] | None:
    """(first-project, second-project) session dictations of speaker a (keys
    of kind "session"): the two projects with most dictations, larger first;
    None if the speaker has fewer than two projects with SESSION_MIN."""
    pools: dict[str, list[str]] = {}
    for r in cache.by_key.values():
        if r["speaker"] == a and r["kind"] == "session":
            pools.setdefault(r["project"], []).append(r["key"])
    pools = {p: sorted(v, key=lambda k: cache.by_key[k]["j"]) for p, v in pools.items() if len(v) >= SESSION_MIN}
    if len(pools) < 2:
        return None
    first, second = sorted(pools.values(), key=lambda v: (-len(v), v[0]))[:2]
    return first, second


def stream_for(cache: Cache, a: str, c: dict, spouse: str | None) -> list[str] | None:
    """The condition's stream for speaker a, or None if a does not qualify."""
    if "session" in c:
        split = session_split(cache, a)
        if split is None:
            return None
        first, second = split
        mature = first[:3] + _cycled(first[3:], MATURE - 3, f"{a}/session1")  # shared by change and control
        after = second if c["session"] == "change" else first[3:]
        return mature + _cycled(after, c["horizon"] - MATURE, f"{a}/session2/{c['session']}")
    stream = cache.stream(a, dirty=c.get("dirty", False))
    if "horizon" in c:
        stream = _long(stream, c["horizon"], f"{a}/A")
    if c.get("device_change"):
        hs = {k: k.replace("/enroll/", "/enroll_hs/") for k in stream}
        return stream[:MATURE] + [hs[k] for k in stream[MATURE:]]
    if spouse is None:
        return stream
    other = cache.stream(spouse)
    if "poison" in c:
        start = c.get("poison_start", 3)
        return _poisoned(stream, other, c["poison"], f"{a}/{spouse}/{c['poison']}/{len(stream)}/{start}", start)
    if "burst" in c:
        burst = _cycled(other[3:], c["burst"], f"{spouse}/burst")
        return stream[:MATURE] + burst + stream[MATURE + c["burst"]:]
    return stream


@dataclass
class Run:
    """One rule x condition: profiles at each snapshot, which second speaker
    (if any) had a dictation in the stream before each snapshot, and the
    user's own acceptance decisions in order."""

    snaps: dict  # n -> {speaker: EmbProfile}
    involved: dict  # n -> {speaker: second-speaker id}
    accept_user: dict  # speaker -> list of bools (user dictations, in order, with their stream position)
    accept_other: list


def simulate_condition(sc: EmbeddingScorer, cache: Cache, spk: list[str], c: dict, spouse: dict) -> Run:
    run = Run({n: {} for n in c["snaps"]}, {n: {} for n in c["snaps"]}, {}, [])
    for a in spk:
        b = spouse.get(a)
        stream = stream_for(cache, a, c, b)
        if stream is None:
            continue
        first_b = next((i for i, k in enumerate(stream) if b and k.startswith(b + "/")), None)
        prof = sc.enroll_windows([cache.windows(k) for k in stream[:3]])
        user = []
        for i, k in enumerate(stream[3:], start=4):
            before = prof.accepted
            prof = sc.update_windows(prof, cache.windows(k))
            if b and k.startswith(b + "/"):
                run.accept_other.append(prof.accepted > before)
            else:
                user.append((i, prof.accepted > before))
            if i in run.snaps:
                run.snaps[i][a] = prof
                if first_b is not None and first_b < i:
                    run.involved[i][a] = b
        if 3 in run.snaps:
            run.snaps[3][a] = sc.enroll_windows([cache.windows(k) for k in stream[:3]])
        run.accept_user[a] = user
    return run


def _acceptance_blocks(accept_user: dict) -> dict:
    """Genuine acceptance rate per block of ACCEPT_BLOCK stream positions."""
    blocks: dict[int, list[bool]] = {}
    for user in accept_user.values():
        for i, ok in user:
            blocks.setdefault((i - 1) // ACCEPT_BLOCK, []).append(ok)
    return {f"{b * ACCEPT_BLOCK + 1}-{(b + 1) * ACCEPT_BLOCK}": float(np.mean(v)) for b, v in sorted(blocks.items())}


def cmd_simulate(args) -> None:
    from ..harness.halves import half_of

    commit = require_clean(args.smoke)
    cache = Cache.load("dev", args.embedder, args.smoke)
    kinds = {r["kind"] for r in cache.by_key.values()}
    if not {"enroll", "enroll_hs", "target", "target_hs"} <= kinds:
        raise ValueError(f"dev cache lacks {sorted({'enroll', 'enroll_hs', 'target', 'target_hs'} - kinds)}; "
                         "it predates the change conditions: rebuild it with `adapt embed`")
    gates = load_gates(args.embedder, args.norm, args.smoke)
    spk = cache.speakers()
    sex = sex_of("dev")
    half = {s: half_of(s) for s in spk}
    sidx = {s: i for i, s in enumerate(spk)}
    spouses = {same: {a: spouse_of(a, spk, sex, half, same) for a in spk} for same in (True, False)}
    targets = {}
    for kind, name in (("target", "builtin"), ("target_hs", "headset")):
        t_rows, t_spk = [], []
        for s in spk:
            for j in range(10):
                k = f"{s}/{kind}/{j}"
                if k in cache.by_key:
                    e = cache.windows(k).emb[::EVAL_STRIDE]
                    t_rows.append(e)
                    t_spk += [sidx[s]] * e.shape[0]
        T, t_spk = np.concatenate(t_rows), np.array(t_spk)
        targets[name] = (T, t_spk, {s: _unit(T[t_spk == sidx[s]].mean(0)) for s in spk})
    mults = M.speaker_multiplicities(len(spk), args.n_boot, 20261022)
    results: dict = {"embedder": args.embedder, "norm": args.norm, "gates": gates, "window": WINDOW.__dict__,
                     "n_boot": args.n_boot, "git": commit, "cache": cache.provenance,
                     "smoke": bool(args.smoke or cache.provenance["smoke"] or gates.get("smoke", True)),
                     "conditions": {}, "paired": {}, "change": {},
                     "caveats": ["contaminating speakers of the 20 % stream are not resampled (as in W0's harness)",
                                 "long horizons replay a few distinct cached dictations (27 updates; session "
                                 f"change: {SESSION_MIN}-{SESSION_CAP} per project): replay dynamics, not months of "
                                 "fresh acoustic variation, which is untested",
                                 f"drift floor calibrated over {CALIBRATION_HORIZON} cycled train dictations"]}
    conds = conditions()
    for name, c in conds.items():
        if "base" in c and not set(c["snaps"]) <= set(conds[c["base"]]["snaps"]):
            raise ValueError(f"{name}: snapshots {c['snaps']} not all in its base {c['base']}")

    memo: dict = {}

    def evaluate(sc, run: Run, n: int, names: list[str], target_set: str):
        key = (id(run), n, tuple(names), target_set)
        if key not in memo:  # a condition's own evaluation and its paired re-evaluation often coincide
            T, t_spk, centroids = targets[target_set]
            profs = {a: run.snaps[n][a] for a in names}
            memo[key] = _evaluate(sc, profs, spk, sidx, T, t_spk, spouses, centroids, mults, run.involved[n])
        return memo[key]

    for rule in RULES:
        memo.clear()
        sc = make_scorer(args.embedder, rule, gates, args.norm, args.survey_root)
        runs = {cname: simulate_condition(sc, cache, spk, c, spouses[c["same_sex"]] if "same_sex" in c else {})
                for cname, c in conds.items()}
        for cname, c in conds.items():
            run = runs[cname]
            tset = c.get("targets", "builtin")
            cres = {"n_speakers": len(run.accept_user), "targets": tset,
                    "accept_rate_other": float(np.mean(run.accept_other)) if run.accept_other else None,
                    "accept_rate_user_by_block": _acceptance_blocks(run.accept_user), "by_k": {}}
            for n in c["snaps"]:
                rel = {a: cache.relation(a, min(n, 30)) for a in run.snaps[n]}
                for subset in ("headline", "all"):
                    names = [a for a in spk if a in run.snaps[n] and (subset == "all" or rel[a] not in HEADLINE_EXCLUDES)]
                    if not names:
                        continue
                    cres["by_k"][f"{n}|{subset}"] = evaluate(sc, run, n, names, tset)[0]
                    if "base" in c:  # paired on the speakers both conditions have, same targets, same replicates
                        base = runs[c["base"]]
                        common = [a for a in names if a in base.snaps[n]]
                        _, r = evaluate(sc, run, n, common, tset)
                        _, rb = evaluate(sc, base, n, common, tset)
                        results["paired"][f"{rule}|{cname}-{c['base']}|{n}|{subset}"] = {
                            "n_speakers": len(common), "targets": tset,
                            **{m: M.paired_difference(r[m][0], r[m][1], rb[m][0], rb[m][1]).as_dict()
                               for m in ("eer_all", "eer_spouse_samesex", "eer_spouse_crosssex")}}
            if c.get("change"):
                results["change"][f"{rule}|{cname}"] = change_acceptance(
                    run, runs[c["base"]], mults, sidx)
            results["conditions"][f"{rule}|{cname}"] = cres
            print(rule, cname, json.dumps({k: round(v["eer_all"]["value"], 4) for k, v in cres["by_k"].items()
                                           if k.endswith("headline")}), flush=True)
    d = OUT / "results"
    d.mkdir(parents=True, exist_ok=True)
    (d / f"{args.embedder}_{args.norm}.json").write_text(json.dumps(results, indent=1))


def _rate(user: list, lo: int, hi: int) -> float:
    v = [ok for i, ok in user if lo < i <= hi]
    return float(np.mean(v)) if v else np.nan


def change_acceptance(run: Run, base: Run, mults: np.ndarray, sidx: dict) -> dict:
    """H5-change, with speaker-bootstrap CIs (pre-registered thresholds):
    ratio = genuine acceptance in the last block of the horizon / in the last
    block before the change (pooled over speakers, resampled with the same
    replicates as everything else). follows if the CI lower bound is >= 0.8,
    locks_out if the CI upper bound is < 0.5, else inconclusive. The ratio is
    unidentifiable when the pooled pre-change acceptance is zero (verdict
    "unidentifiable"), and the CI is not trusted when more than 2.5 % of
    replicates have a zero denominator (verdict "inconclusive"). Also the
    paired difference in last-block acceptance, change minus its control."""
    names = [a for a in run.accept_user if a in base.accept_user]
    if not names:
        return {"n_speakers": 0, "verdict": "no qualifying speakers"}
    horizon = max(i for a in names for i, _ in run.accept_user[a])
    pre = np.array([_rate(run.accept_user[a], MATURE - CHANGE_BLOCK, MATURE) for a in names])
    last = np.array([_rate(run.accept_user[a], horizon - CHANGE_BLOCK, horizon) for a in names])
    ctrl = np.array([_rate(base.accept_user[a], horizon - CHANGE_BLOCK, horizon) for a in names])
    ok = np.isfinite(pre) & np.isfinite(last) & np.isfinite(ctrl)
    idx = np.array([sidx[a] for a in names])[ok]
    pre, last, ctrl = pre[ok], last[ok], ctrl[ok]
    if idx.size == 0:
        return {"n_speakers": 0, "verdict": "no qualifying speakers"}

    def stats(w):
        den = np.average(pre, weights=w)
        ratio = np.average(last, weights=w) / den if den > 0 else np.nan
        return ratio, np.average(last, weights=w) - np.average(ctrl, weights=w)

    point = stats(np.ones(idx.size))
    reps = np.array([stats(m[idx]) for m in mults if m[idx].sum() > 0])
    diff_lo, diff_hi = np.percentile(reps[:, 1], [2.5, 97.5])
    out = {"n_speakers": int(idx.size), "pre_rate": float(pre.mean()), "last_rate": float(last.mean()),
           "control_last_rate": float(ctrl.mean()),
           "last_minus_control": {"value": float(point[1]), "lo": float(diff_lo), "hi": float(diff_hi)}}
    finite = np.isfinite(reps[:, 0])
    if not np.isfinite(point[0]):
        out.update(ratio=None, verdict="unidentifiable")
        return out
    lo, hi = np.percentile(reps[finite, 0], [2.5, 97.5])
    out["ratio"] = {"value": float(point[0]), "lo": float(lo), "hi": float(hi),
                    "zero_denominator_replicates": float(1 - finite.mean())}
    if 1 - finite.mean() > 0.025:
        out["verdict"] = "inconclusive"
    else:
        out["verdict"] = "follows" if lo >= 0.8 else "locks_out" if hi < 0.5 else "inconclusive"
    return out


def _evaluate(sc, profs: dict, spk, sidx, T, t_spk, spouses, true_centroid, mults, involved: dict):
    """Profiles vs all held-out target windows: EER with all impostors, and
    spouse EER (the user's windows vs one second speaker's only) for both
    spouse assignments, so every condition is comparable with its baseline.
    Joint-role bootstrap: when a second speaker's dictation was in a
    profile's stream before this snapshot (`involved`), every trial of that
    profile also needs that speaker drawn. Returns (summary, {metric: (point,
    replicates)})."""
    names = [a for a in spk if a in profs]
    S = np.stack([sc.window_scores(profs[a], T)[0] for a in names])
    ms = np.repeat(np.array([sidx[a] for a in names]), T.shape[0])
    ts = np.tile(t_spk, len(names))
    extra = np.repeat(np.array([sidx[involved[a]] if a in involved else -1 for a in names]), T.shape[0])
    s, lab = S.ravel(), ms == ts
    out, reps = {"n_speakers": len(names)}, {}
    e, r = M.bootstrap_multi({"eer": M.eer_from_roc}, s, lab, ms, ts, mults, extra_spk=extra)["eer"]
    out["eer_all"], reps["eer_all"] = e.as_dict(), (e.value, r)
    for same, tag in ((True, "samesex"), (False, "crosssex")):
        bidx = np.array([sidx[spouses[same][spk[m]]] for m in ms])
        keep = lab | (ts == bidx)
        e, r = M.bootstrap_multi({"eer": M.eer_from_roc}, s[keep], lab[keep], ms[keep], ts[keep], mults,
                                 extra_spk=extra[keep])["eer"]
        out[f"eer_spouse_{tag}"], reps[f"eer_spouse_{tag}"] = e.as_dict(), (e.value, r)
        out[f"cos_to_spouse_{tag}"] = float(np.mean([profs[a].directions[0] @ true_centroid[spouses[same][a]]
                                                     for a in names]))
    out["cos_to_true"] = float(np.mean([profs[a].directions[0] @ true_centroid[a] for a in names]))
    return out, reps


H4_MARGIN = 0.005  # +0.5 EER points (fractions here)
H5_MARGIN = 0.01  # +1 point of spouse EER


def verdict(ci: dict, margin: float, good: str, bad: str) -> str:
    """Pre-registered three-outcome rule on a paired difference (condition minus base)."""
    if ci["hi"] < margin:
        return good
    if ci["lo"] > margin:
        return bad
    return "inconclusive"


def _pct(c: dict | None) -> str:
    return "-" if not c else f"{100 * c['value']:+.2f} [{100 * c['lo']:+.2f}, {100 * c['hi']:+.2f}]"


def render_report(res: dict) -> str:
    """Stage C tables with the pre-registered verdicts (DESIGN H4, H5, H5-long, H5-change)."""
    lines = [f"# Stage C: {res['embedder']} ({res['norm']}), git {res['git']}{' SMOKE' if res.get('smoke') else ''}", "",
             "Caveats: " + "; ".join(res["caveats"]), ""]
    lines += ["## Growth (clean stream, headline speakers): EER % [95 % CI]", "",
              "| rule | k = 3 | k = 10 | k = 30 | user accept |", "|---|---|---|---|---|"]
    rules = sorted({k.split("|")[0] for k in res["conditions"]}, key=RULES.index)
    for r in rules:
        c = res["conditions"][f"{r}|clean"]
        cells = [_pct(c["by_k"].get(f"{k}|headline", {}).get("eer_all")).replace("+", "") for k in (3, 10, 30)]
        acc = c["accept_rate_user_by_block"]
        lines.append(f"| {r} | " + " | ".join(cells) + f" | {np.mean(list(acc.values())):.2f} |")
    lines += ["", "## H4 contamination (20 %), EER difference vs clean (points), verdict at margin +0.5", "",
              "| rule | k = 10 | k = 30 | verdict k = 30 |", "|---|---|---|---|"]
    for r in rules:
        p10 = res["paired"].get(f"{r}|contaminated20-clean|10|headline", {}).get("eer_all")
        p30 = res["paired"].get(f"{r}|contaminated20-clean|30|headline", {}).get("eer_all")
        lines.append(f"| {r} | {_pct(p10)} | {_pct(p30)} | {verdict(p30, H4_MARGIN, 'robust', 'harmed') if p30 else '-'} |")
    lines += ["", "## H5 poisoning, spouse EER difference vs clean (points) at k = 30, verdict at margin +1", "",
              "| rule | condition | difference | verdict | spouse accept |", "|---|---|---|---|---|"]
    for r in rules:
        for cname, snap in [(f"poison{p}_{x}", 30) for p in (30, 50) for x in ("samesex", "crosssex")] + \
                           [(f"long_mature_poison{p}_samesex", 600) for p in (10, 30, 50)] + \
                           [("long_mature_burst20_samesex", 320), ("long_mature_burst20_samesex", 600)]:
            key = f"{r}|{cname}-{'long_clean' if cname.startswith('long') else 'clean'}|{snap}|headline"
            pr = res["paired"].get(key)
            if not pr:
                continue
            m = "eer_spouse_crosssex" if "crosssex" in cname else "eer_spouse_samesex"
            acc = res["conditions"][f"{r}|{cname}"]["accept_rate_other"]
            lines.append(f"| {r} | {cname} @ {snap} | {_pct(pr[m])} | {verdict(pr[m], H5_MARGIN, 'resists', 'poisoned')} "
                         f"| {acc:.2f} |")
    lines += ["", "## H5-change: genuine acceptance after a change (ratio last / pre-change block)", "",
              "| rule | condition | n | pre | last | ratio [CI] | last - control [CI] | verdict |",
              "|---|---|---|---|---|---|---|---|"]
    for key, c in res.get("change", {}).items():
        r, cname = key.split("|")
        if c.get("n_speakers", 0) == 0:
            lines.append(f"| {r} | {cname} | 0 | - | - | - | - | {c['verdict']} |")
            continue
        ratio = c.get("ratio")
        rs = "-" if not ratio else f"{ratio['value']:.2f} [{ratio['lo']:.2f}, {ratio['hi']:.2f}]"
        d = c["last_minus_control"]
        lines.append(f"| {r} | {cname} | {c['n_speakers']} | {c['pre_rate']:.2f} | {c['last_rate']:.2f} | {rs} | "
                     f"{d['value']:+.2f} [{d['lo']:+.2f}, {d['hi']:+.2f}] | {c['verdict']} |")
    return "\n".join(lines) + "\n"


def cmd_report(args) -> None:
    d = OUT / "results"
    for f in sorted(d.glob("*.json")):
        res = json.loads(f.read_text())
        f.with_suffix(".md").write_text(render_report(res))
        print(f.with_suffix(".md").read_text())


def main(argv=None) -> None:
    ap = argparse.ArgumentParser(prog="lfspk.embed.adapt")
    sub = ap.add_subparsers(dest="cmd", required=True)
    e = sub.add_parser("embed")
    e.add_argument("--split", choices=("dev", "train"), required=True)
    e.add_argument("--embedders", nargs="+", required=True)
    e.add_argument("--device", default="cpu")
    e.add_argument("--limit", type=int, default=None, help="smoke runs only: first N speakers")
    e.add_argument("--smoke", action="store_true", help="allow uncommitted code (not a result)")
    for name in ("calibrate", "simulate"):
        p = sub.add_parser(name)
        p.add_argument("--embedder", required=True)
        p.add_argument("--norm", choices=("raw", "asnorm"), default="asnorm")
        p.add_argument("--survey-root", type=Path, default=None)
        p.add_argument("--smoke", action="store_true", help="allow uncommitted code (not a result)")
        if name == "simulate":
            p.add_argument("--n-boot", type=int, default=1000)
    sub.add_parser("report")
    args = ap.parse_args(argv)
    {"embed": cmd_embed, "calibrate": cmd_calibrate, "simulate": cmd_simulate, "report": cmd_report}[args.cmd](args)


if __name__ == "__main__":
    main()
