"""D1 diagnostic (DESIGN.md sections 6 and 9): does the PVAD use the embedding?

    ./python -m lfspk.pvad.diag_swap --set <dev set> --checkpoint RUNS/W3/train/<run>/final.pt

On the frozen dev set's coherent-room S4 mixtures (one second dictator), each
mixture is scored twice in float64 target log-odds: with its target's
(10, clean, built-in) profile, as the harness enrolls it, and with a profile of
its interferer. The interferer's 10 dictations come from its own clean
built-in enrollment stream, excluding every utterance of that speaker used in
any mixture of the set, and preferring utterances from a LibriVox project
(then a chapter) other than the scored mixture's interferer utterances; the
relation reached is recorded per mixture.

Pre-registered criterion (revised twice in review, eval-r1 and eval-r2,
before any data). Per mixture, on single-speaker frames only (label 1
target-only vs label 2 interferer-only), the AUC of the target log-odds under
three profiles: own (the target's), swap (the interferer's) and random (a unit
vector drawn from a fixed per-mixture seed), plus an unrelated control (a
same-sex dev speaker absent from the mixture). A rank statistic, so a
contraction of the logits or a mixture-wide shift cannot pass it. Statistics:
means over mixtures, with the joint (target, interferer) bootstrap. The model
uses identity iff the CI of mean AUC_swap lies below 0.5 and the CI of
mean(AUC_own - AUC_random) lies above 0. The earlier pooled log-odds deltas
and pooled AUCs are reported as diagnostics only. Retained and excluded
mixtures are counted by speaker, role and reason; the conclusion holds for
the eligible population only.
Exploratory (all dev speakers). Output: RUNS/W3/diag/<run>-D1.json.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import re
from pathlib import Path
from typing import Mapping, Sequence

import numpy as np

from lfspk import paths

from .devmon import K_ENROLL, check_dev
from .enrollment import parse_chapters_txt, unit, utterance_chapter
from .harness_scorer import make
from .metrics import FrameRanks, frame_bootstrap, joint_bootstrap, roc_auc

OUT = paths.RUNS / "W3" / "diag"
_UTT = re.compile(r"^\d+-\d+-\d+$")
RELATIONS = ("cross_project", "same_project_cross_chapter", "same_chapter")


def _strings(x):
    if isinstance(x, str):
        yield x
    elif isinstance(x, dict):
        for v in x.values():
            yield from _strings(v)
    elif isinstance(x, (list, tuple)):
        for v in x:
            yield from _strings(v)


def mixture_utterances(manifest: Sequence[dict]) -> dict[str, set[str]]:
    """speaker -> every LibriSpeech utterance of theirs placed in any mixture of
    the set (as target or as any interferer)."""
    out: dict[str, set[str]] = {}
    for r in manifest:
        for s in _strings([r["meta"]["target"].get("utt"), r["meta"].get("interferers", [])]):
            if _UTT.match(s):
                out.setdefault(s.split("-")[0], set()).add(s)
    return out


def relation(utt: str, against: Sequence[str], chapter_project: Mapping[str, str]) -> str:
    projs = {chapter_project[utterance_chapter(u)] for u in against}
    chaps = {utterance_chapter(u) for u in against}
    if chapter_project[utterance_chapter(utt)] not in projs:
        return "cross_project"
    return "same_project_cross_chapter" if utterance_chapter(utt) not in chaps else "same_chapter"


def choose_swap_dictations(stream: Sequence[dict], used: set[str], against: Sequence[str],
                           chapter_project: Mapping[str, str], k: int = K_ENROLL) -> tuple[list[dict], str] | None:
    """k stream rows disjoint from `used`, strongest relation to `against` first
    (stream order within a relation); None if fewer than k remain. Returns the
    rows and the weakest relation among them."""
    cands = [r for r in stream if r["utt"] not in used]
    rel = {r["utt"]: relation(r["utt"], against, chapter_project) for r in cands}
    ordered = sorted(cands, key=lambda r: RELATIONS.index(rel[r["utt"]]))  # stable
    if len(ordered) < k:
        return None
    chosen = ordered[:k]
    return chosen, max((rel[r["utt"]] for r in chosen), key=RELATIONS.index)


def single_speaker_deltas(own: Sequence[np.ndarray], swap: Sequence[np.ndarray], labels: Sequence[np.ndarray]):
    """Per item: (sum and count of swapped - own over label-1 frames, same over label-2)."""
    st, ct, si, ci = [], [], [], []
    for a, b, lab in zip(own, swap, labels):
        d = np.asarray(b, np.float64) - np.asarray(a, np.float64)
        st.append(d[lab == 1].sum()), ct.append(float((lab == 1).sum()))
        si.append(d[lab == 2].sum()), ci.append(float((lab == 2).sum()))
    return tuple(np.asarray(v) for v in (st, ct, si, ci))


def delta_bootstrap(own, swap, labels, items, n_boot: int = 1000, seed: int = 0) -> dict:
    """Diagnostic only (not the criterion): pooled mean (swapped - own) log-odds."""
    st, ct, si, ci = single_speaker_deltas(own, swap, labels)

    def ratio(s, c):
        return lambda w: float((w * s).sum() / (w * c).sum()) if (w * c).sum() > 0 else float("nan")

    return {"delta_target": joint_bootstrap(items, ratio(st, ct), n_boot=n_boot, seed=seed),
            "delta_interferer": joint_bootstrap(items, ratio(si, ci), n_boot=n_boot, seed=seed)}


def single_speaker_auc(score: np.ndarray, lab: np.ndarray) -> float:
    """AUC of label-1 (target-only) against label-2 (interferer-only) frames."""
    return roc_auc(np.asarray(score)[lab == 1], np.asarray(score)[lab == 2])


def mean_bootstrap(values: np.ndarray, items, n_boot: int = 1000, seed: int = 0) -> dict:
    v = np.asarray(values, np.float64)
    return joint_bootstrap(items, lambda w: float((w * v).sum() / w.sum()) if w.sum() > 0 else float("nan"),
                           n_boot=n_boot, seed=seed)


def auc_criterion(auc_own, auc_swap, auc_random, items, n_boot: int = 1000, seed: int = 0) -> dict:
    """The pre-registered D1 decision from per-mixture single-speaker AUCs."""
    out = {"mean_auc_own": mean_bootstrap(auc_own, items, n_boot, seed),
           "mean_auc_swap": mean_bootstrap(auc_swap, items, n_boot, seed),
           "mean_auc_random": mean_bootstrap(auc_random, items, n_boot, seed),
           "mean_own_minus_random": mean_bootstrap(np.asarray(auc_own) - np.asarray(auc_random), items, n_boot, seed)}
    out["uses_identity"] = bool(out["mean_auc_swap"]["hi"] < 0.5 and out["mean_own_minus_random"]["lo"] > 0)
    return out


def random_profile(mixture_id: str, dim: int):
    from .scorer import PVADProfile

    seed = int(hashlib.sha256(f"w3-d1-random/{mixture_id}".encode()).hexdigest()[:15], 16)
    v = np.random.default_rng(seed).normal(size=dim).astype(np.float32)
    return PVADProfile(1, unit(v))


def summarize(auc: dict, own, swap, labels, items, attrition: dict, n_considered: int, n_boot: int = 1000) -> dict:
    """The D1 report. With no retained mixture the result is inconclusive, but
    the attrition counts are still reported."""
    population = {"mixtures_retained": len(items), "mixtures_considered": n_considered,
                  "target_speakers": len({t for t, _ in items}), "interferer_speakers": len({i for _, i in items}),
                  "by_speaker": attrition}
    out = {"population": population,
           "criterion": "uses identity iff CI(mean AUC_swap) < 0.5 and CI(mean(AUC_own - AUC_random)) > 0 "
                        "(per-mixture AUC, label 1 vs label 2 frames); holds for the retained population only",
           "label": "exploratory (all dev speakers that are eligible)"}
    if not items:
        out.update({"uses_identity": None, "inconclusive": "no mixture retained"})
        return out
    out.update(auc_criterion(auc["own"], auc["swap"], auc["random"], items, n_boot))
    unrel = np.asarray(auc["unrelated"])
    ok = np.isfinite(unrel)
    out["control_mean_auc_unrelated"] = (mean_bootstrap(unrel[ok], [it for it, k in zip(items, ok) if k], n_boot)
                                         if ok.any() else None)
    out["diagnostic_pooled_deltas"] = delta_bootstrap(own, swap, labels, items, n_boot)
    out["diagnostic_pooled_auc_own"] = frame_bootstrap(FrameRanks(own, labels), items, "auc_tgt_vs_intf", n_boot=n_boot)
    out["diagnostic_pooled_auc_swapped"] = frame_bootstrap(FrameRanks(swap, labels), items, "auc_tgt_vs_intf",
                                                           n_boot=n_boot)
    return out


def run(set_id: str, checkpoint: Path, n_boot: int = 1000) -> Path:
    from lfspk import splits
    from lfspk.harness.frozen import FrozenSet

    fs = FrozenSet(set_id)
    check_dev(fs.manifest)
    chapter_project = parse_chapters_txt((paths.LIBRISPEECH / "CHAPTERS.TXT").read_text(encoding="utf-8", errors="replace"))
    sex = {s_.id: s_.sex for s_ in splits.speakers("dev")}
    used = mixture_utterances(fs.manifest)
    sc = make(str(checkpoint))
    if sc.cfg.conditioning == "none":
        raise ValueError("D1 needs a conditioned model")
    rows = [r for r in fs.manifest if r["scenario"] == "S4" and r.get("rir_mode", "coherent") == "coherent"]
    cache: dict[tuple, object] = {}

    def enroll(rows_):
        key = tuple(r["file"] for r in rows_)
        if key not in cache:
            cache[key] = sc.enroll([fs.audio(r["file"]) for r in rows_])
        return cache[key]

    streams = {s_: fs.enrollment_stream(s_, "builtin", contaminated=False) for s_ in sorted({str(r["speaker"]) for r in fs.manifest})}
    own, swap, labels, items, rel_counts = [], [], [], [], {}
    auc = {"own": [], "swap": [], "random": [], "unrelated": []}
    attrition: dict[str, dict[str, int]] = {}

    def drop(reason: str, tgt: str, ispk: str | None):
        for role, spk in (("target", tgt), ("interferer", ispk)):
            if spk:
                d = attrition.setdefault(spk, {})
                d[f"{role}:{reason}"] = d.get(f"{role}:{reason}", 0) + 1

    for r in rows:
        tgt = str(r["speaker"])
        ints = [i for i in r["meta"]["interferers"] if i.get("speaker")]
        if len(ints) != 1:
            drop("not_one_dictator", tgt, None)
            continue
        ispk = str(ints[0]["speaker"])
        if len(streams.get(tgt, [])) < K_ENROLL:
            drop("target_stream_short", tgt, ispk)
            continue
        against = [u for u in _strings(ints[0]) if _UTT.match(u)]
        pick = choose_swap_dictations(streams.get(ispk, []), used.get(ispk, set()), against, chapter_project)
        if pick is None:
            drop("swap_candidates_short", tgt, ispk)
            continue
        lab = fs.labels(r)["labels"]
        if not ((lab == 1).any() and (lab == 2).any()):
            drop("no_single_speaker_frames", tgt, ispk)
            continue
        others = sorted((s_ for s_ in streams if s_ not in (tgt, ispk) and sex.get(s_) == sex.get(tgt)
                         and len(streams[s_]) >= K_ENROLL),
                        key=lambda s_: hashlib.sha256(f"w3-d1-unrelated/{r['id']}/{s_}".encode()).hexdigest())
        chosen, rel = pick
        rel_counts[rel] = rel_counts.get(rel, 0) + 1
        audio = fs.audio(r["files"]["mix"]).astype(np.float32)
        lo_own = sc.log_odds(enroll(streams[tgt][:K_ENROLL]), audio)
        lo_swap = sc.log_odds(enroll(chosen), audio)
        lo_rand = sc.log_odds(random_profile(r["id"], sc.cfg.emb_dim), audio)
        auc["own"].append(single_speaker_auc(lo_own, lab))
        auc["swap"].append(single_speaker_auc(lo_swap, lab))
        auc["random"].append(single_speaker_auc(lo_rand, lab))
        auc["unrelated"].append(single_speaker_auc(sc.log_odds(enroll(streams[others[0]][:K_ENROLL]), audio), lab)
                                if others else float("nan"))
        own.append(lo_own), swap.append(lo_swap), labels.append(lab), items.append((tgt, ispk))
        for role, spk in (("target", tgt), ("interferer", ispk)):
            d = attrition.setdefault(spk, {})
            d[f"{role}:retained"] = d.get(f"{role}:retained", 0) + 1
    res = {"set_id": set_id, "set_hash": fs.hash, "checkpoint": str(checkpoint), "k_enroll": K_ENROLL,
           "swap_profile_relations": rel_counts,
           **summarize(auc, own, swap, labels, items, attrition, len(rows), n_boot)}
    OUT.mkdir(parents=True, exist_ok=True)
    path = OUT / f"{Path(checkpoint).parent.name}-D1.json"
    path.write_text(json.dumps(res, indent=1))
    return path


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--set", required=True)
    ap.add_argument("--checkpoint", required=True, type=Path)
    a = ap.parse_args()
    print(run(a.set, a.checkpoint))


if __name__ == "__main__":
    main()
