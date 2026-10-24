"""Harness sanity checks (DESIGN.md section 1, claims C1-C5) on a dev scenario set.

    ./python -m lfspk.harness.sanity all --set dev-v1 [--out FILE.json]

C3: Parakeet WER on the dry dev utterances (needs `utt:` keys in the ASR cache).
C4: requested vs measured SIR/SNR from the manifest.
C5: activity labels vs Parakeet word spans on the dry target tracks.
Also: label fractions per scenario, interferer-word yield (hypothesis words
attributed to interferers per mixture, and per pseudo-reference word), and the
oracle frame fraction of correctly recognised target words under candidate
word windows (how well TDT word spans line up with the acoustics).
Dev only: refuses split 'test'.
"""

from __future__ import annotations

import argparse
import collections
import json
import sys
from pathlib import Path
from typing import Any

import numpy as np

from .align import align, error_counts, frame_span, normalize, tokens_from_words, Word
from .asr import read_cache
from .frozen import FrozenSet
from .refs import ASR_DIR, read_words


def c3_dry_wer(asr: dict[str, Any], split: str = "dev") -> dict[str, Any]:
    from .corpora import Corpus

    c = Corpus(split)
    out: dict[str, Any] = {}
    agg: dict[str, list[int]] = collections.defaultdict(lambda: [0, 0])
    for s in c.speakers:
        sub = c.subset[s]
        for u in c.utterances[s]:
            k = f"utt:{u.id}"
            if k not in asr:
                continue
            hyp = [Word(t, 0, 0) for t in normalize(asr[k]["text"])]
            ref = [Word(t, 0, 0) for t in normalize(u.text)]
            e = error_counts(align(hyp, ref, timed=False))
            agg[sub][0] += e["S"] + e["D"] + e["I"]
            agg[sub][1] += len(ref)
    for sub, (err, n) in sorted(agg.items()):
        out[sub] = {"wer": err / n if n else None, "ref_words": n}
    return out


def c4_levels(fs: FrozenSet) -> dict[str, Any]:
    sir_err, snr_err = [], []
    for r in fs.manifest:
        m = r["meta"]
        for it in m["interferers"]:
            sir_err.append(abs(it["sir_measured_db"] - it["sir_db"]))
        snr_err.append(abs(m["ambience"]["snr_measured_db"] - m["ambience"]["snr_db"]))
    return {"max_abs_sir_error_db": float(max(sir_err)) if sir_err else None, "max_abs_snr_error_db": float(max(snr_err))}


def label_stats(fs: FrozenSet) -> dict[str, Any]:
    acc: dict[str, list[np.ndarray]] = collections.defaultdict(list)
    ovl: dict[str, list[float]] = collections.defaultdict(list)
    for r in fs.manifest:
        key = f"{r['scenario']}/{r.get('rir_mode', 'coherent')}"
        lab = fs.labels(r)["labels"]
        acc[key].append(np.bincount(lab, minlength=4))
        t = np.sum((lab == 1) | (lab == 3))
        ovl[key].append(float(np.sum(lab == 3) / t) if t else 0.0)
    return {k: {"label_fractions": (np.sum(v, axis=0) / np.sum(v)).round(4).tolist(), "overlap_of_target_mean": float(np.mean(ovl[k]))} for k, v in sorted(acc.items())}


def c5_activity_vs_words(fs: FrozenSet, asr: dict[str, Any]) -> dict[str, Any]:
    """On dry target tracks of S0 mixtures: share of word-span frames labelled
    active, and share of active frames within 0.1 s of a word span."""
    in_words = act_frames = act_near = word_frames = 0
    for r in fs.manifest:
        if r["scenario"] != "S0" or r.get("rir_mode", "coherent") != "coherent":
            continue
        act = fs.labels(r)["target_active"]
        F = act.size
        span = np.zeros(F, bool)
        near = np.zeros(F, bool)
        for w in tokens_from_words([tuple(x) for x in asr[f"tdry:{r['id']}"]["words"]]):
            f0, f1 = frame_span(w.start, w.end, F)
            span[f0:f1] = True
            near[max(0, f0 - 10) : min(F, f1 + 10)] = True
        in_words += int(np.sum(act & span))
        word_frames += int(np.sum(span))
        act_frames += int(np.sum(act))
        act_near += int(np.sum(act & near))
    return {"word_frames_active": in_words / max(1, word_frames), "active_frames_near_words": act_near / max(1, act_frames)}


def interferer_yield(fs: FrozenSet, words: dict[str, Any]) -> dict[str, Any]:
    out: dict[str, Any] = {}
    by: dict[str, list[tuple[int, int, float]]] = collections.defaultdict(list)
    for r in fs.manifest:
        w = words[r["id"]]
        n_hyp = sum(1 for t in w["tokens"] if t[4] == "interferer")
        n_ref = sum(w["n_interferer_ref"])
        sirs = [it["sir_db"] for it in r["meta"]["interferers"]]
        by[f"{r['scenario']}/{r.get('rir_mode', 'coherent')}"].append((n_hyp, n_ref, float(np.mean(sirs)) if sirs else float("nan")))
    for k, v in sorted(by.items()):
        a = np.array(v, dtype=float)
        if not np.isfinite(a[:, 2]).any():
            out[k] = {"mixtures": len(v), "interferer_hyp_words_per_mixture": float(a[:, 0].mean())}
            continue
        bins = {}
        for lo, hi in ((-10, 0), (0, 5), (5, 10), (10, 20)):
            m = (a[:, 2] >= lo) & (a[:, 2] < hi)
            if m.any():
                bins[f"{lo}..{hi}"] = {"mixtures": int(m.sum()), "hyp_per_ref_word": float(a[m, 0].sum() / max(1, a[m, 1].sum()))}
        out[k] = {"mixtures": len(v), "interferer_hyp_words_per_mixture": float(a[:, 0].mean()),
                  "mixtures_with_none": float(np.mean(a[:, 0] == 0)), "hyp_per_ref_word": float(a[:, 0].sum() / max(1, a[:, 1].sum())), "by_sir": bins}
    return out


def target_dropout(fs: FrozenSet, words: dict[str, Any], asr: dict[str, Any]) -> dict[str, Any]:
    """ASR failure independent of filtering: mixtures in which Parakeet loses
    more than half of the target words (substitutions + deletions over target
    reference words, untimed alignment of the mixture hypothesis; interferer
    insertions are not counted) while the dry target track alone transcribes
    with WER <= 10 %. Per scenario and RIR mode."""
    out: dict[str, Any] = {}
    for r in fs.manifest:
        key = f"{r['scenario']}/{r.get('rir_mode', 'coherent')}"
        w = words[r["id"]]
        n = max(1, sum(w["n_ref"].values()))
        lost = (w["untimed_errors"]["S"] + w["untimed_errors"]["D"]) / n
        ref = [Word(t, 0, 0) for t in normalize(r["meta"]["target"]["text"])]
        dry = [Word(t, 0, 0) for t in normalize(asr[f"tdry:{r['id']}"]["text"])]
        e = error_counts(align(dry, ref, timed=False))
        dry_wer = (e["S"] + e["D"] + e["I"]) / max(1, len(ref))
        d = out.setdefault(key, {"mixtures": 0, "dropout": 0, "ids": []})
        d["mixtures"] += 1
        if lost > 0.5 and dry_wer <= 0.1:
            d["dropout"] += 1
            d["ids"].append(r["id"])
    for d in out.values():
        d["rate"] = d["dropout"] / max(1, d["mixtures"])
        d["ids"] = d["ids"][:20]
    return out


def attribution_crosscheck(fs: FrozenSet, words: dict[str, Any]) -> dict[str, Any]:
    """Share of hypothesis tokens attributed to the same source with true
    (aligned) references and with Parakeet pseudo-references, per scenario."""
    acc: dict[str, list[float]] = collections.defaultdict(list)
    for r in fs.manifest:
        w = words[r["id"]]
        if "attribution_agreement_pseudo" in w and w["tokens"]:
            acc[f"{r['scenario']}/{r.get('rir_mode', 'coherent')}"].append(w["attribution_agreement_pseudo"])
    return {k: {"mixtures": len(v), "mean_agreement": float(np.mean(v))} for k, v in sorted(acc.items())}


def word_window_oracle(fs: FrozenSet, words: dict[str, Any], windows: list[tuple[float, float]]) -> dict[str, Any]:
    """For correct target tokens (attribution target/C) and interferer tokens of
    coherent mixtures: oracle frame fraction (target-active share of the
    window) under each candidate window [start - a, end + b]."""
    res = {}
    labs = {r["id"]: fs.labels(r)["labels"] for r in fs.manifest if r.get("rir_mode", "coherent") == "coherent"}
    for a, b in windows:
        tgt, intf, tgt_s0 = [], [], []
        for r in fs.manifest:
            if r["id"] not in labs:
                continue
            lab = labs[r["id"]]
            t = (lab == 1) | (lab == 3)
            for tok in words[r["id"]]["tokens"]:
                f0, f1 = frame_span(max(0.0, tok[10] - a), tok[11] + b, lab.size)
                v = float(t[f0:f1].mean())
                if tok[4] == "target" and tok[5] == "C":
                    tgt.append(v)
                    if r["scenario"] == "S0":
                        tgt_s0.append(v)
                elif tok[4] == "interferer":
                    intf.append(v)
        tgt, intf, tgt_s0 = np.array(tgt), np.array(intf), np.array(tgt_s0)
        tau = float(np.quantile(tgt, 0.005)) if tgt.size else float("nan")
        res[f"{a:+.2f},{b:+.2f}"] = {
            "target_frac_below_0.5": float(np.mean(tgt < 0.5)), "target_S0_frac_below_0.5": float(np.mean(tgt_s0 < 0.5)),
            "target_q005": tau, "interferer_kept_at_q005": float(np.mean(intf >= tau)) if intf.size else None, "n_target": int(tgt.size), "n_interferer": int(intf.size),
        }
    return res


def label_validation(asr_path: Path, split: str = "dev") -> dict[str, Any]:
    """Forced-alignment labels (primary and no-merge) against Parakeet word spans
    on the dry utterances, and the energy-rule diagnostic; plus CTC-vs-Parakeet
    boundary statistics on correctly matched words. Dev only."""
    from ..api import frame_count
    from .activity import activity
    from .corpora import Corpus
    from .forced import GAP_S, NO_MERGE_GAP_S, words_to_frames
    from .util import load_audio

    if split != "dev":
        raise SystemExit("label validation runs on dev only")
    c = Corpus(split)
    asr = read_cache(asr_path)
    acc: dict[str, list[tuple[float, float, float]]] = collections.defaultdict(list)
    d_start, d_end, g_ctc, g_pk = [], [], [], []
    n = 0
    for s in c.speakers:
        for u in c.utterances[s]:
            words = c.alignment(u.id)
            k = f"utt:{u.id}"
            if not words or k not in asr:
                continue
            n += 1
            F = frame_count(u.samples)
            hyp = tokens_from_words([tuple(t) for t in asr[k]["words"]])
            pk = np.zeros(F, bool)
            for w in hyp:
                f0, f1 = frame_span(w.start, w.end, F)
                pk[f0:f1] = True
            en = activity(load_audio(u.path))[:F]
            for name, gap in (("primary", GAP_S), ("nomerge", NO_MERGE_GAP_S)):
                fa = words_to_frames(words, F, gap_s=gap)
                for ref_name, ref in (("parakeet", pk), ("energy", en)):
                    acc[f"{name}_vs_{ref_name}"].append(((fa == ref).mean(), (fa & ref).sum() / max(1, ref.sum()), (fa & ref).sum() / max(1, fa.sum())))
            ref_w = [Word(t.lower(), a, b) for t, a, b in words]
            pairs = [(i, j) for op, i, j in align(hyp, ref_w, timed=False) if op == "C"]
            for i, j in pairs:
                d_start.append(ref_w[j].start - hyp[i].start)
                d_end.append(ref_w[j].end - hyp[i].end)
            for (i1, j1), (i2, j2) in zip(pairs, pairs[1:]):
                if j2 == j1 + 1 and i2 == i1 + 1:
                    g_ctc.append(ref_w[j2].start - ref_w[j1].end)
                    g_pk.append(hyp[i2].start - hyp[i1].end)
    out: dict[str, Any] = {"utterances": n}
    for k, v in acc.items():
        a = np.array(v)
        out[k] = {"frame_agreement": float(a[:, 0].mean()), "recall_of_reference": float(a[:, 1].mean()), "precision": float(a[:, 2].mean())}
    q = lambda x: [float(np.percentile(x, p)) for p in (25, 50, 75)]
    out["ctc_minus_parakeet_start_s_q25_50_75"] = q(d_start)
    out["ctc_minus_parakeet_end_s_q25_50_75"] = q(d_end)
    out["gap_between_matched_words"] = {"ctc_median": float(np.median(g_ctc)), "parakeet_median": float(np.median(g_pk)),
                                         "ctc_share_ge_40ms": float(np.mean(np.array(g_ctc) >= 0.04)), "parakeet_share_ge_40ms": float(np.mean(np.array(g_pk) >= 0.04))}
    return out


def main(argv: list[str] | None = None) -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("cmd", choices=["all", "labels"])
    ap.add_argument("--set", default=None)
    ap.add_argument("--asr", type=Path, default=None, help="ASR cache with utt: keys (labels)")
    ap.add_argument("--out", type=Path, default=None)
    a = ap.parse_args(argv)
    if a.cmd == "labels":
        text = json.dumps(label_validation(a.asr), indent=1)
        if a.out:
            a.out.write_text(text)
        print(text)
        return
    fs = FrozenSet(a.set)
    if any(r["meta"]["split"] == "test" for r in fs.manifest[:1]):
        raise SystemExit("sanity checks run on dev sets only")
    asr = read_cache(ASR_DIR / a.set / "asr.jsonl")
    words = read_words(a.set)
    windows = [(0.0, 0.0), (0.08, 0.0), (0.0, 0.08), (0.08, 0.08), (0.16, 0.0), (0.16, 0.08), (0.24, 0.0), (0.08, -0.08), (0.16, -0.08)]
    res = {
        "set": a.set, "hash": fs.hash,
        "c3_dry_wer": c3_dry_wer(asr),
        "c4_levels": c4_levels(fs),
        "c5_activity_vs_words": c5_activity_vs_words(fs, asr),
        "labels": label_stats(fs),
        "interferer_yield": interferer_yield(fs, words),
        "target_dropout": target_dropout(fs, words, asr),
        "attribution_crosscheck": attribution_crosscheck(fs, words),
        "word_window_oracle": word_window_oracle(fs, words, windows),
    }
    text = json.dumps(res, indent=1)
    if a.out:
        a.out.write_text(text)
    print(text)


if __name__ == "__main__":
    sys.exit(main())
