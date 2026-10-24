"""Stage A: intrinsic embedder survey on dev (dev-clean + dev-other; DESIGN.md, Stage A).

  ./python[-nemo] -m lfspk.embed.survey embed --embedder NAME [--device cuda]
  ./python -m lfspk.embed.survey score [--n-boot 1000]

`embed` writes, under RUNS/W1/survey/emb/<NAME>/:
  dev_full.f32.npy + dev_full.tsv   every dev utterance, full length
  dev_seg.f32.npy  + dev_seg.tsv    test-pool utterances, one segment per
                                    (length, seed), placed by protocol.place_segment
  cohort_full / cohort_seg          2 train utterances per train speaker, full
                                    and one segment per length (seed 0 placement)
  meta.json                         embedder, weights hash, git commit, counts
Embeddings are L2-normalised float32 rows; .tsv rows align with .npy rows.

`score` reads every embedder directory present and writes
RUNS/W1/survey/results/{intrinsic.json,intrinsic.md}.
"""

from __future__ import annotations

import argparse
import csv
import json
import os
import subprocess
import time
from pathlib import Path

import numpy as np

from .. import paths, splits
from ..api import SAMPLE_RATE
from . import metrics as M
from . import norm as N
from . import protocol as P
from .audio import load

OUT = paths.RUNS / "W1" / "survey"
COHORT_PER_SPEAKER = 2
COHORT_SEED = 7
LENGTHS = P.SEGMENT_SECONDS
KS = (1, 3, 10, 30)
TOP_KS = (50, 100, 200, 400)
P_TARGETS = (0.01, 0.05)


# Every repository path a W1 run executes: W1's code, the shared modules, and
# W0's harness (mixtures, halves, utilities).
EXECUTED_PATHS = ("lfspk/__init__.py", "lfspk/api.py", "lfspk/splits.py", "lfspk/paths.py", "lfspk/embed",
                  "lfspk/harness", "python", "python-nemo")


def git_commit() -> str:
    """HEAD, suffixed "-dirty" if any executed path has uncommitted changes."""
    try:
        root = Path(__file__).resolve().parents[2]
        out = subprocess.run(["git", "-C", str(root), "rev-parse", "HEAD"], capture_output=True, text=True, check=True)
        dirty = subprocess.run(["git", "-C", str(root), "status", "--porcelain", "--", *EXECUTED_PATHS],
                               capture_output=True, text=True, check=True).stdout.strip()
        return out.stdout.strip() + ("-dirty" if dirty else "")
    except Exception:  # pragma: no cover
        return "unknown"


def require_clean(smoke: bool) -> str:
    """The commit a real run executes; refuses to run (not a smoke run) when
    any executed path is dirty, so every artefact cites reproducible code."""
    commit = git_commit()
    if not smoke and (commit == "unknown" or commit.endswith("-dirty")):
        raise RuntimeError(f"refusing a real run from uncommitted code ({commit}); commit first or pass --smoke")
    return commit


def cohort_utterances(limit: int | None = None) -> list[tuple[splits.Speaker, Path]]:
    """2 utterances of every cohort-role train speaker (protocol.cohort_role)."""
    out = []
    for s in [s for s in splits.speakers("train") if P.cohort_role(s.id) == "cohort"][:limit]:
        utts = splits.utterances(s)
        rng = np.random.default_rng([COHORT_SEED, int(s.id)])
        pick = sorted(rng.choice(len(utts), size=min(COHORT_PER_SPEAKER, len(utts)), replace=False))
        out.extend((s, utts[i]) for i in pick)
    return out


def _write(dirpath: Path, stem: str, emb: np.ndarray, rows: list[dict]) -> None:
    np.save(dirpath / f"{stem}.f32.npy", emb.astype(np.float32))
    with open(dirpath / f"{stem}.tsv", "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=list(rows[0]), delimiter="\t")
        w.writeheader()
        w.writerows(rows)


def _read(dirpath: Path, stem: str) -> tuple[np.ndarray, list[dict]]:
    emb = np.load(dirpath / f"{stem}.f32.npy")
    with open(dirpath / f"{stem}.tsv", newline="") as f:
        rows = list(csv.DictReader(f, delimiter="\t"))
    if len(rows) != emb.shape[0]:
        raise ValueError(f"{dirpath}/{stem}: {len(rows)} rows vs {emb.shape[0]} embeddings")
    return emb, rows


def _embed_items(model, items: list[tuple[dict, np.ndarray]], batch: int = 256) -> np.ndarray:
    out = []
    for i in range(0, len(items), batch):
        out.append(model.embed_batch([a for _, a in items[i:i + batch]]))
    return np.concatenate(out) if out else np.zeros((0, model.dim), np.float32)


def cmd_embed(args) -> None:
    paths.require_mount()
    commit = require_clean(args.smoke)
    from .embedder import load_embedder

    if args.device.startswith("cuda"):
        import torch

        frac = os.environ.get("AGENT_JOBS_VRAM_FRACTION")
        if frac:
            torch.cuda.set_per_process_memory_fraction(float(frac))
    model = load_embedder(args.embedder, args.device)
    d = Path(args.out) / "emb" / args.embedder
    d.mkdir(parents=True, exist_ok=True)
    t0 = time.time()
    plans = P.plan("dev")
    test_ids = {P.utt_id(u) for p in plans for u in p.test}
    full, segs = [], []
    for p in plans:
        for u in sorted(p.enroll + p.test):
            a = load(u)
            meta = {"utt": P.utt_id(u), "speaker": p.speaker.id, "sex": p.speaker.sex, "chapter": P.chapter_of(u),
                    "pool": "test" if P.utt_id(u) in test_ids else "enroll", "dur_s": f"{a.size / SAMPLE_RATE:.3f}"}
            full.append((meta, a))
            if meta["pool"] == "test":
                for sec in LENGTHS:
                    for seed in P.SEEDS:
                        start, n, ok = P.place_segment(a, sec, P.segment_rng(seed, meta["utt"], sec))
                        segs.append(({"utt": meta["utt"], "speaker": p.speaker.id, "sex": p.speaker.sex,
                                      "len_s": sec, "seed": seed, "start": start, "n": n, "placed_ok": int(ok)},
                                     a[start:start + n]))
    _write(d, "dev_full", _embed_items(model, full), [m for m, _ in full])
    _write(d, "dev_seg", _embed_items(model, segs), [m for m, _ in segs])
    dev_fallbacks = sum(1 for m, _ in segs if not m["placed_ok"])
    del full, segs
    cf, cs = [], []
    for s, u in cohort_utterances(args.cohort_speakers):
        a = load(u)
        cf.append(({"utt": P.utt_id(u), "speaker": s.id, "sex": s.sex}, a))
        for sec in LENGTHS:
            start, n, ok = P.place_segment(a, sec, P.segment_rng(0, P.utt_id(u), sec))
            cs.append(({"utt": P.utt_id(u), "speaker": s.id, "sex": s.sex, "len_s": sec, "start": start, "n": n,
                        "placed_ok": int(ok)}, a[start:start + n]))
    _write(d, "cohort_full", _embed_items(model, cf), [m for m, _ in cf])
    _write(d, "cohort_seg", _embed_items(model, cs), [m for m, _ in cs])
    fallbacks = {"dev_seg": dev_fallbacks, "cohort_seg": sum(1 for m, _ in cs if not m["placed_ok"])}
    meta = {"embedder": model.name, "dim": model.dim, "params": getattr(model, "params", None),
            "placement_fallbacks": fallbacks,
            "weights_sha256": model.weights_sha256, "git": commit, "smoke": args.smoke, "device": args.device,
            "seconds": round(time.time() - t0, 1), "dev_full": len(full := _read(d, "dev_full")[1]),
            "date": time.strftime("%Y-%m-%d")}
    (d / "meta.json").write_text(json.dumps(meta, indent=2))
    print(json.dumps(meta))


# ---------------------------------------------------------------- scoring

class Survey:
    """Loaded embeddings of one embedder, organised for trials."""

    def __init__(self, d: Path):
        self.meta = json.loads((d / "meta.json").read_text())
        self.full, frows = _read(d, "dev_full")
        self.full_rows = frows
        self.seg, srows = _read(d, "dev_seg")
        self.cfull, _ = _read(d, "cohort_full")
        cseg, crows = _read(d, "cohort_seg")
        self.cseg = {sec: cseg[[float(r["len_s"]) == sec for r in crows]] for sec in LENGTHS}
        self.cohort_rows = _read(d, "cohort_full")[1]
        plans = P.plan("dev")
        self.speakers = [p.speaker for p in plans]
        self.relation = np.array([p.relation for p in plans])
        try:  # W0's canonical halves; lazily imported, optional for non-half tables
            halves = P.dev_half(self.speakers)
            self.half = np.array([halves[s.id] for s in self.speakers])
        except ImportError:
            self.half = None
        self.subset = np.array([s.subset for s in self.speakers])
        spk_index = {s.id: i for i, s in enumerate(self.speakers)}
        self.sex = np.array([s.sex for s in self.speakers])
        row_of = {r["utt"]: i for i, r in enumerate(frows)}
        self.enroll_rows = [[row_of[P.utt_id(u)] for u in p.enroll] for p in plans]
        test_rows = [row_of[P.utt_id(u)] for p in plans for u in p.test]
        self.tests = {"full": (self.full[test_rows], np.array([spk_index[frows[i]["speaker"]] for i in test_rows]))}
        sspk = np.array([spk_index[r["speaker"]] for r in srows])
        slen = np.array([float(r["len_s"]) for r in srows])
        sseed = np.array([int(r["seed"]) for r in srows])
        for sec in LENGTHS:
            m = slen == sec
            self.tests[sec] = (self.seg[m], sspk[m], sseed[m])

    def profiles(self, k: int) -> tuple[np.ndarray, np.ndarray]:
        """Unit-normalised mean of the first k enrollment embeddings, and the
        number actually used per speaker."""
        prof, used = [], []
        for rows in self.enroll_rows:
            e = self.full[rows[:k]].mean(axis=0)
            prof.append(e / np.linalg.norm(e))
            used.append(min(k, len(rows)))
        return np.stack(prof).astype(np.float32), np.array(used)


def trials(scores: np.ndarray, test_spk: np.ndarray, keep_models=None, keep_tests=None, same_sex_of=None):
    """Flatten an (n_models, n_tests) score matrix into trial arrays
    (scores, is_target, model speaker, test speaker).
    `keep_models` / `keep_tests`: boolean masks over speakers restricting the
    enrolled side / the test side. `same_sex_of`: speaker sexes; if given,
    non-target trials across sexes are dropped."""
    n_models = scores.shape[0]
    model_spk = np.repeat(np.arange(n_models), scores.shape[1])
    tspk = np.tile(test_spk, n_models)
    s = scores.ravel()
    keep = np.ones(s.size, bool)
    if keep_models is not None:
        keep &= keep_models[model_spk]
    if keep_tests is not None:
        keep &= keep_tests[tspk]
    if same_sex_of is not None:
        keep &= (model_spk == tspk) | (same_sex_of[model_spk] == same_sex_of[tspk])
    return s[keep], (model_spk == tspk)[keep], model_spk[keep], tspk[keep]


def subsets(sv: "Survey") -> dict[str, dict]:
    """Trial subsets reported for every variant. Relation subsets restrict the
    enrolled speaker (impostors stay all dev speakers); halves restrict both sides."""
    out = {"all": {}, "samesex": {"same_sex_of": sv.sex}}
    for rel in (P.CROSS_PROJECT, P.SAME_PROJECT, P.SAME_CHAPTER):
        out[rel] = {"keep_models": sv.relation == rel}
    for h in "AB" if sv.half is not None else "":
        out[f"half{h}"] = {"keep_models": sv.half == h, "keep_tests": sv.half == h}
    for sub in ("dev-clean", "dev-other"):
        m = sv.subset == sub
        out[sub.replace("-", "")] = {"keep_models": m, "keep_tests": m}
    return out


# Pre-stated CI tables (DESIGN.md): AS-norm uses K = 200, fixed in advance.
CI_SUBSETS = ("all", "samesex", P.CROSS_PROJECT, "halfA", "halfB", "devclean", "devother")


def want_ci(k: int, variant: str, subset: str) -> bool:
    if subset == "all":
        return variant == "raw" or (k == 10 and variant in ("snorm", "asnorm200"))
    return subset in CI_SUBSETS and k == 10 and variant == "raw"


OPERATING_FNR = (0.005, 0.01)  # target-segment miss budgets near the contract's 0.5 % word budget


def _metrics(roc) -> dict:
    return {"eer": M.eer_from_roc(roc), **{f"mindcf{p}": M.min_dcf_from_roc(roc, p) for p in P_TARGETS},
            **{f"fpr@fnr{f}": M.fpr_at_fnr_from_roc(roc, f) for f in OPERATING_FNR}}


CI_METRICS = {"eer": M.eer_from_roc, "mindcf0.01": lambda r: M.min_dcf_from_roc(r, 0.01),
              **{f"fpr@fnr{f}": (lambda r, f=f: M.fpr_at_fnr_from_roc(r, f)) for f in OPERATING_FNR}}


def score_variants(sv: Survey, k: int, length) -> dict:
    """Score matrices for every normalisation variant at one (k, length)."""
    prof, _ = sv.profiles(k)
    tests = sv.tests[length][0]
    ctest = sv.cfull if length == "full" else sv.cseg[length]
    out = {"raw": N.score_matrix(prof, tests)}
    out["snorm"] = N.score_matrix(prof, tests, cohort_profile=sv.cfull, cohort_test=ctest)
    for K in (k for k in TOP_KS if k <= len(sv.cfull)):
        out[f"asnorm{K}"] = N.score_matrix(prof, tests, cohort_profile=sv.cfull, cohort_test=ctest, top_k=K)
        if length != "full":
            out[f"asnorm{K}-fullcohort"] = N.score_matrix(prof, tests, cohort_profile=sv.cfull,
                                                          cohort_test=sv.cfull, top_k=K)
    return out


def seen_speaker_check(sv: Survey, n_boot: int, seed: int) -> dict:
    """Descriptive diagnostic only (not a membership test): within-speaker
    cosine of two full utterances from the same chapter, train-clean-360
    cohort speakers minus dev-clean speakers (dev-other is excluded to match
    recording quality). Pairs are drawn the same way on both sides (two
    distinct utterances of one chapter, seeded per speaker). Differences
    between embedders are suggestive at most; TitaNet's unspecified LibriSpeech
    training overlap stays flagged whatever this shows."""
    by_spk: dict[str, list[int]] = {}
    for i, r in enumerate(sv.cohort_rows):
        by_spk.setdefault(r["speaker"], []).append(i)
    train_cos = []
    for rows in by_spk.values():  # cohort utterances were drawn uniformly; keep same-chapter pairs
        if len(rows) >= 2 and sv.cohort_rows[rows[0]]["utt"].split("-")[1] == sv.cohort_rows[rows[1]]["utt"].split("-")[1]:
            train_cos.append(float(sv.cfull[rows[0]] @ sv.cfull[rows[1]]))
    train_cos = np.array(train_cos)
    dev_cos = []
    for i, rows in enumerate(sv.enroll_rows):
        if sv.speakers[i].subset != "dev-clean":
            continue
        first_chapter = [r for r in rows if sv.full_rows[r]["chapter"] == sv.full_rows[rows[0]]["chapter"]]
        if len(first_chapter) < 2:
            continue
        rng = np.random.default_rng([COHORT_SEED, int(sv.speakers[i].id)])
        a, b = rng.choice(len(first_chapter), 2, replace=False)
        dev_cos.append(float(sv.full[first_chapter[a]] @ sv.full[first_chapter[b]]))
    dev_cos = np.array(dev_cos)
    mults_train = M.speaker_multiplicities(train_cos.size, n_boot, seed)
    mults_dev = M.speaker_multiplicities(dev_cos.size, n_boot, seed + 1)
    bt = np.array([np.average(train_cos, weights=m) for m in mults_train])
    bd = np.array([np.average(dev_cos, weights=m) for m in mults_dev])
    diff = bt - bd
    return {"train_within_cos": float(train_cos.mean()), "dev_within_cos": float(dev_cos.mean()),
            "n_train_pairs": int(train_cos.size), "n_dev_pairs": int(dev_cos.size),
            "gap": float(train_cos.mean() - dev_cos.mean()),
            "gap_ci": [float(np.percentile(diff, 2.5)), float(np.percentile(diff, 97.5))]}


def embedding_provenance(sv: "Survey", name: str, args, commit: str) -> dict | None:
    """Check the embeddings' provenance for a real run. Smoke or uncommitted
    embeddings need --smoke, or an explicit --accept-embed-provenance entry
    with --provenance-reason, which is returned as an audit record (for smoke
    and dirty inputs alike) and stored with the results."""
    upstream = {"git": sv.meta.get("git", "unknown"), "smoke": bool(sv.meta.get("smoke", False))}
    bad = upstream["smoke"] or str(upstream["git"]).endswith(("-dirty", "unknown"))
    accepted = name in getattr(args, "accept_embed_provenance", []) and bool(getattr(args, "provenance_reason", ""))
    if bad and not args.smoke and not accepted:
        raise RuntimeError(f"{name}: embeddings from a smoke or uncommitted run ({upstream}); "
                           "rebuild, pass --smoke, or list it in --accept-embed-provenance with --provenance-reason")
    if bad and accepted:
        return {"embedding_label": upstream["git"], "embedding_smoke": upstream["smoke"],
                "reason": args.provenance_reason, "scored_at": commit}
    return None


def cmd_score(args) -> None:
    paths.require_mount()
    commit = require_clean(args.smoke)
    out_root = Path(args.out)
    names = args.embedders or sorted(p.name for p in (out_root / "emb").iterdir() if (p / "meta.json").is_file())
    res: dict = {"git": commit, "smoke": args.smoke, "n_boot": args.n_boot, "boot_seed": args.boot_seed,
                 "embedders": {}}
    n_spk = len(P.plan("dev"))
    mults = M.speaker_multiplicities(n_spk, args.n_boot, args.boot_seed)
    res["n_speakers"] = n_spk
    for name in names:
        t0 = time.time()
        sv = Survey(out_root / "emb" / name)
        override = embedding_provenance(sv, name, args, commit)
        er: dict = {"meta": sv.meta, "point": {}, "ci": {}, "per_seed": {}, "smoke": args.smoke,
                    "provenance_override": override,
                    "speakers": [s.id for s in sv.speakers], "halves_available": sv.half is not None}
        primary_reps = {}
        subs = subsets(sv)
        for length in ("full",) + LENGTHS:
            tspk = sv.tests[length][1]
            for k in KS:
                variants = score_variants(sv, k, length)
                for vname, S in variants.items():
                    for subset, kw in subs.items():
                        s, lab, ms, ts = trials(S, tspk, **kw)
                        key = f"{length}|k{k}|{vname}|{subset}"
                        er["point"][key] = _metrics(M.SortedTrials(s, lab).roc())
                        if length != "full" and subset == "all" and vname == "raw":
                            seeds = sv.tests[length][2]
                            er["per_seed"][key] = {
                                int(sd): M.eer(*trials(S[:, seeds == sd], tspk[seeds == sd])[:2]) for sd in P.SEEDS}
                        if want_ci(k, vname, subset) and args.n_boot > 0:
                            b = M.bootstrap_multi(CI_METRICS, s, lab, ms, ts, mults)
                            er["ci"][key] = {m: e.as_dict() for m, (e, _) in b.items()}
                            primary_reps[key] = {m: (e.value, reps) for m, (e, reps) in b.items()}
        er["enroll_used"] = {str(k): sv.profiles(k)[1].tolist() for k in KS}
        # Paired differences on shared replicates (k = 10 unless stated, all speakers).
        er["paired"] = {}
        for metric in ("eer", "fpr@fnr0.01"):
            for length in ("full",) + LENGTHS:
                def get(k, v):
                    r = primary_reps.get(f"{length}|k{k}|{v}|all")
                    return r[metric] if r else None
                pairs = [(f"{v}-raw", get(10, v), get(10, "raw")) for v in ("snorm", "asnorm200")]
                pairs += [(f"k{a}-k{b}", get(a, "raw"), get(b, "raw")) for a, b in ((10, 3), (30, 10))]
                for label, a, b in pairs:
                    if a and b:
                        er["paired"][f"{metric}|{length}|{label}"] = M.paired_difference(a[0], a[1], b[0], b[1]).as_dict()
        er["seen_speaker_check"] = seen_speaker_check(sv, max(args.n_boot, 200), args.boot_seed + 1)
        er["score_seconds"] = round(time.time() - t0, 1)
        d = out_root / "results"
        d.mkdir(parents=True, exist_ok=True)
        one = {k: v for k, v in res.items() if k != "embedders"} | {"embedders": {name: er}}
        (d / f"intrinsic_{name}.json").write_text(json.dumps(one, indent=1))
        print(name, "scored in", er["score_seconds"], "s", flush=True)


def cmd_render(args) -> None:
    d = Path(args.out) / "results"
    res: dict = {}
    for f in sorted(d.glob("intrinsic_*.json")):
        one = json.loads(f.read_text())
        if res and {k: one[k] for k in ("n_boot", "boot_seed")} != {k: res[k] for k in ("n_boot", "boot_seed")}:
            raise ValueError(f"{f}: bootstrap settings differ from the other embedders")
        emb = one.pop("embedders")
        res = res or one | {"embedders": {}}
        res["smoke"] = bool(res.get("smoke")) or bool(one.get("smoke"))
        for name, er in emb.items():
            first = next(iter(res["embedders"].values()), er)
            if er["speakers"] != first["speakers"]:
                raise ValueError(f"{name}: speaker population differs from the other embedders")
        res["embedders"].update(emb)
    (d / "intrinsic.json").write_text(json.dumps(res, indent=1))
    (d / "intrinsic.md").write_text(render(res))
    print((d / "intrinsic.md").read_text())


def _fmt(c) -> str:
    return f"{100 * c['value']:.2f} ({100 * c['lo']:.2f}-{100 * c['hi']:.2f})" if c else "-"


def _table(res: dict, title: str, key_fn, metric: str = "eer") -> list[str]:
    hdr = ["embedder", "params"] + [f"{x}s" for x in LENGTHS] + ["full"]
    lines = ["", f"## {title}", "", "| " + " | ".join(hdr) + " |", "|" + "---|" * len(hdr)]
    for name, er in res["embedders"].items():
        cells = [name, f"{(er['meta'].get('params') or 0) / 1e6:.2f} M"]
        for length in LENGTHS + ("full",):
            cells.append(_fmt(er["ci"].get(key_fn(length), {}).get(metric)))
        lines.append("| " + " | ".join(cells) + " |")
    return lines


def render(res: dict) -> str:
    smoke = [n for n, er in res["embedders"].items() if er.get("smoke") or er["meta"].get("smoke")]
    missing = [n for n, er in res["embedders"].items() if not er.get("halves_available", True)]
    banner = ([f"**INCOMPLETE: selection-aware half analysis skipped (halves module unavailable) for: "
               f"{', '.join(missing)}. Half A/B tables are empty; do not select on these results.**", ""]
              if missing else [])
    if smoke:
        banner = [f"**SMOKE RUN, NOT A RESULT: {', '.join(smoke)}.**", ""] + banner
    lines = banner + [f"# Stage A intrinsic results (git {res['git']}, {res.get('n_speakers', '?')} dev speakers)", "",
             f"EER % (95 % CI, joint speaker bootstrap, n = {res['n_boot']}); profiles = mean of the first k "
             "enrollment utterances; test segments from 3 seeds pooled."]
    lines += _table(res, "Primary: k = 10, raw cosine, all dev speakers", lambda L: f"{L}|k10|raw|all")
    lines += _table(res, "k = 10, raw cosine, cross-project enrollment only",
                    lambda L: f"{L}|k10|raw|{P.CROSS_PROJECT}")
    lines += _table(res, "k = 10, raw cosine, same-sex impostors only", lambda L: f"{L}|k10|raw|samesex")
    lines += _table(res, "k = 10, raw cosine, dev-clean only", lambda L: f"{L}|k10|raw|devclean")
    lines += _table(res, "k = 10, raw cosine, dev-other only", lambda L: f"{L}|k10|raw|devother")
    lines += _table(res, "k = 10, raw cosine, dev half B (selection-free half)", lambda L: f"{L}|k10|raw|halfB")
    lines += _table(res, "k = 10, AS-norm (K = 200), all", lambda L: f"{L}|k10|asnorm200|all")
    lines += _table(res, "minDCF(0.01), k = 10, raw cosine, all", lambda L: f"{L}|k10|raw|all", "mindcf0.01")
    lines += _table(res, "Impostor pass rate % at 1 % target miss, k = 10, raw cosine, all",
                    lambda L: f"{L}|k10|raw|all", "fpr@fnr0.01")
    lines += _table(res, "Impostor pass rate % at 0.5 % target miss, k = 10, raw cosine, all",
                    lambda L: f"{L}|k10|raw|all", "fpr@fnr0.005")
    lines += _table(res, "Impostor pass rate % at 1 % target miss, k = 10, raw cosine, half A (selection half)",
                    lambda L: f"{L}|k10|raw|halfA", "fpr@fnr0.01")
    lines += ["", "## Paired differences (EER points x100, 95 % CI): normalisation and profile size", ""]
    for name, er in res["embedders"].items():
        cells = [f"{k}: {_fmt(v)}" for k, v in er.get("paired", {}).items()]
        lines.append(f"- {name}: " + "; ".join(cells))
    lines += ["", "## Seen-speaker diagnostic (descriptive; same-chapter within-speaker cosine, train-clean-360 "
              "cohort minus dev-clean)", ""]
    for name, er in res["embedders"].items():
        c = er["seen_speaker_check"]
        lines.append(f"- {name}: train {c['train_within_cos']:.3f}, dev {c['dev_within_cos']:.3f}, "
                     f"gap {c['gap']:+.3f} (95 % CI {c['gap_ci'][0]:+.3f} to {c['gap_ci'][1]:+.3f})")
    return "\n".join(lines) + "\n"


def cmd_compare(args) -> None:
    """Paired cross-embedder differences (A minus B) on shared speaker
    replicates (same seed and population as `score`), for the pre-stated H1
    size claim and the shortlist frontier. Writes results/compare.json."""
    paths.require_mount()
    commit = require_clean(args.smoke)
    out_root = Path(args.out)
    mults = None
    reps: dict = {}
    overrides: dict = {}
    halves_missing = False
    for name in sorted(set(sum((p.split(":") for p in args.pairs), []))):
        sv = Survey(out_root / "emb" / name)
        overrides[name] = embedding_provenance(sv, name, args, commit)
        halves_missing |= sv.half is None
        if mults is None:
            mults = M.speaker_multiplicities(len(sv.speakers), args.n_boot, args.boot_seed)
        prof, _ = sv.profiles(10)
        subsets_ = [("all", {})] + ([] if sv.half is None else
                                    [("halfB", {"keep_models": sv.half == "B", "keep_tests": sv.half == "B"})])
        for length in [x for x in (1.0, 1.5) if x in sv.tests]:
            tests, tspk = sv.tests[length][0], sv.tests[length][1]
            S_ = N.score_matrix(prof, tests)
            for subset, kw in subsets_:
                s, lab, ms, ts = trials(S_, tspk, **kw)
                b = M.bootstrap_multi(CI_METRICS, s, lab, ms, ts, mults)
                reps[(name, length, subset)] = {m: (e.value, r) for m, (e, r) in b.items()}
    res = {"git": commit, "smoke": args.smoke, "n_boot": args.n_boot, "boot_seed": args.boot_seed, "pairs": {},
           "provenance_overrides": overrides,
           "incomplete": "halves module unavailable: half-B comparisons skipped" if halves_missing else None}
    for pair in args.pairs:
        a, b = pair.split(":")
        for (name, length, subset), ra in reps.items():
            if name != a:
                continue
            if (b, length, subset) not in reps:
                continue
            rb = reps[(b, length, subset)]
            for m in ("eer", "fpr@fnr0.01"):
                res["pairs"][f"{a}-{b}|{length}|k10|raw|{subset}|{m}"] = M.paired_difference(
                    ra[m][0], ra[m][1], rb[m][0], rb[m][1]).as_dict()
    d = out_root / "results"
    (d / "compare.json").write_text(json.dumps(res, indent=1))
    print(json.dumps(res, indent=1))


def cmd_tail(args) -> None:
    """Descriptive tail analysis (not pre-registered; exploratory). For each
    embedder, k = 10, raw cosine, at the pooled threshold giving 1 % target
    miss: how target misses distribute over speakers (how many speakers carry
    50 % and 90 % of them, and who they are), and the headline metrics
    recomputed without the listed speakers (both roles removed)."""
    paths.require_mount()
    commit = require_clean(args.smoke)
    out_root = Path(args.out)
    res = {"git": commit, "smoke": args.smoke, "exclude": args.exclude, "label": "exploratory", "embedders": {}}
    for name in args.embedders:
        sv = Survey(out_root / "emb" / name)
        prof, used = sv.profiles(10)
        er = {"provenance_override": embedding_provenance(sv, name, args, commit)}
        for length in (1.0, 1.5):
            tests, tspk = sv.tests[length][0], sv.tests[length][1]
            S_ = N.score_matrix(prof, tests)
            s, lab, ms, ts = trials(S_, tspk)
            thr = float(np.quantile(s[lab], 0.01))
            miss = np.array([int((S_[i, tspk == i] < thr).sum()) for i in range(len(sv.speakers))])
            order = np.argsort(-miss, kind="stable")
            cum = np.cumsum(miss[order]) / max(miss.sum(), 1)
            keep = np.array([sp.id not in args.exclude for sp in sv.speakers])
            mults = M.speaker_multiplicities(int(keep.sum()), args.n_boot, args.boot_seed)
            # Re-index the kept speakers 0..n-1 so the bootstrap draws only from them.
            remap = -np.ones(len(sv.speakers), int)
            remap[keep] = np.arange(keep.sum())
            s2, lab2, ms2, ts2 = trials(S_, tspk, keep_models=keep, keep_tests=keep)
            b = M.bootstrap_multi(CI_METRICS, s2, lab2, remap[ms2], remap[ts2], mults)
            er[str(length)] = {
                "threshold": thr, "total_misses": int(miss.sum()),
                "speakers_for_50pct": int(np.searchsorted(cum, 0.5) + 1),
                "speakers_for_90pct": int(np.searchsorted(cum, 0.9) + 1),
                "speakers_with_any_miss": int((miss > 0).sum()), "n_speakers": len(sv.speakers),
                "top": [{"speaker": sv.speakers[i].id, "subset": sv.speakers[i].subset,
                         "relation": str(sv.relation[i]), "misses": int(miss[i]),
                         "targets": int((tspk == i).sum()), "k_used": int(used[i])} for i in order[:8]],
                "without_excluded": {m: e.as_dict() for m, (e, _) in b.items()},
            }
        res["embedders"][name] = er
    d = out_root / "results"
    (d / "tail.json").write_text(json.dumps(res, indent=1))
    print(json.dumps(res, indent=1))


def main(argv=None) -> None:
    ap = argparse.ArgumentParser(prog="lfspk.embed.survey")
    sub = ap.add_subparsers(dest="cmd", required=True)
    e = sub.add_parser("embed")
    e.add_argument("--embedder", required=True)
    e.add_argument("--device", default="cpu")
    e.add_argument("--cohort-speakers", type=int, default=None, help="smoke runs only: first N train speakers")
    e.add_argument("--out", default=str(OUT))
    e.add_argument("--smoke", action="store_true", help="allow uncommitted code (not a result)")
    s = sub.add_parser("score")
    s.add_argument("--embedders", nargs="*")
    s.add_argument("--n-boot", type=int, default=1000)
    s.add_argument("--boot-seed", type=int, default=20261021)
    s.add_argument("--out", default=str(OUT))
    s.add_argument("--smoke", action="store_true", help="allow uncommitted code (not a result)")
    s.add_argument("--accept-embed-provenance", nargs="*", default=[],
                   help="embedders whose pre-guard embedding label is accepted (recorded with the results)")
    s.add_argument("--provenance-reason", default="", help="required with --accept-embed-provenance")
    c = sub.add_parser("compare")
    c.add_argument("--pairs", nargs="+", required=True, help="A:B embedder pairs")
    c.add_argument("--n-boot", type=int, default=1000)
    c.add_argument("--boot-seed", type=int, default=20261021)
    c.add_argument("--out", default=str(OUT))
    c.add_argument("--smoke", action="store_true")
    c.add_argument("--accept-embed-provenance", nargs="*", default=[])
    c.add_argument("--provenance-reason", default="")
    t = sub.add_parser("tail")
    t.add_argument("--embedders", nargs="+", required=True)
    t.add_argument("--exclude", nargs="*", default=["1988"])
    t.add_argument("--n-boot", type=int, default=1000)
    t.add_argument("--boot-seed", type=int, default=20261021)
    t.add_argument("--out", default=str(OUT))
    t.add_argument("--smoke", action="store_true")
    t.add_argument("--accept-embed-provenance", nargs="*", default=[])
    t.add_argument("--provenance-reason", default="")
    r = sub.add_parser("render")
    r.add_argument("--out", default=str(OUT))
    args = ap.parse_args(argv)
    {"embed": cmd_embed, "score": cmd_score, "render": cmd_render, "compare": cmd_compare,
     "tail": cmd_tail}[args.cmd](args)


if __name__ == "__main__":
    main()
