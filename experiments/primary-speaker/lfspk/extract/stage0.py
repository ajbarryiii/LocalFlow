"""Stage 0: feasibility screen and pipeline checks on held-out train speakers (DESIGN section 9.0).

    ./python      -m lfspk.extract.stage0 render --workers 6          # CPU: 150 renders per family
    ./python-nemo -m lfspk.extract.stage0 asr --device cuda           # GPU lease: B, B_shuffled, B*, O2, O1
    ./python-nemo -m lfspk.extract.stage0 report                      # CPU: metrics, stop rule, JSON + markdown

Population: the 48 held-out train speakers only. Each family (S0, N, S1-S4)
gets 150 mixtures from W5's example source, with targets and every random
speaker role drawn from the held-out speakers (the generator's `speakers`
pool) and no absent targets. Systems:
- B: plain Parakeet `base`, W0's batching (chunks of 256 in key order, each
  sorted by length, batches of 16).
- B_shuffled: the same model and chunks, batch membership shuffled with a
  fixed seed ("baseline batching sensitivity"; it describes unmasked B only).
- B*: W5's path with log_mask = 0 (diagnostic).
- O2 and O1: the clipped power-ratio oracle masks for T2 (target + noise) and
  T1 (target only), applied raw (C1) through `transcribe_masked`, stored as
  float16 like stage A.
- W_o (report only): the oracle word filter on B, tau at the 0.5 % gross
  budget fitted on these same examples.

Stop rule (pre-registered): stop if (a) R(O2) >= R(W_o) pooled over S1-S4
(points), or (b) O2's gross loss L+ pooled over the six families exceeds 1.0 %
and the lower end of its 95 % joint-speaker CI exceeds 0.5 %. A stop means
only that the raw clipped ratio-mask surrogate does not work with Parakeet on
these mixtures.
"""

from __future__ import annotations

import argparse
import json
import os
import time
from pathlib import Path
from typing import Sequence

import numpy as np

from lfspk import paths

from .data import FAMILIES

OUT = paths.RUNS / "W5" / "stage0"
N_PER_FAMILY = 150
SEED = 20261022
SHUFFLE_SEED = 7
CHUNK = 256
SYSTEMS = ("B", "B_shuffled", "Bstar", "O2", "O1")


# --- render (CPU) ---------------------------------------------------------------------

_SRC = None


def _source():
    global _SRC
    if _SRC is None:
        from lfspk.harness.mix import MixtureGenerator
        from lfspk.pvad.enrollment import librispeech_partitions

        from .data import ExamplePolicy, ExampleSource
        from .overlay import held_out, load_w3_bank

        held = held_out()
        bank, _ = load_w3_bank()
        gen = MixtureGenerator("train", speakers=list(held))
        _SRC = (ExampleSource(gen, librispeech_partitions("train"), bank, held, (), ExamplePolicy(p_absent=0.0)), set(held))
    return _SRC


def _render_one(job: tuple[str, int, str]) -> str:
    fam, i, out = job
    src, held = _source()
    ex = src.example(SEED, FAMILIES.index(fam) * 100_000 + i, family=fam)
    if set(ex.info["interferers"]) - held or ex.info["speaker"] not in held:
        raise AssertionError("a stage-0 mixture involves a speaker outside the held-out set")
    key = f"{fam}-{i:03d}"
    tmp = Path(out) / f"{key}.tmp.npz"
    np.savez(tmp, audio=ex.audio, target_image=ex.target_image, noise=ex.noise, labels=ex.labels,
             meta=np.array(json.dumps(ex.meta)), info=np.array(json.dumps(ex.info)))
    os.replace(tmp, Path(out) / f"{key}.npz")
    return key


def expected_keys(n_per: int) -> list[str]:
    return [f"{f}-{i:03d}" for f in FAMILIES for i in range(n_per)]


def render_identity(n_per: int) -> dict:
    """Everything a stage-0 render depends on (implI2-r1 #3). Renders are reused
    only under an equal identity."""
    import hashlib
    from dataclasses import asdict

    from lfspk.pvad.identity import w0_identity

    from .data import ExamplePolicy
    from .overlay import W3_BANK_SHA256, held_out

    from .train import files_sha256, w3_code_sha256

    here = Path(__file__).resolve().parent
    # stage0.py too: its _source and _render_one choose the pools and examples (as implT-r2 #2 for calibration)
    code_sha = files_sha256([here / f for f in ("api.py", "data.py", "overlay.py", "stage0.py")], here)
    return {"kind": "w5-stage0-render", "seed": SEED, "n_per_family": n_per, "families": list(FAMILIES),
            "index_rule": "FAMILIES.index(family) * 100000 + i", "policy": json.loads(json.dumps(asdict(ExamplePolicy(p_absent=0.0)))),
            "held_out_sha256": hashlib.sha256(",".join(sorted(held_out(), key=int)).encode()).hexdigest(),
            "w3_bank_sha256": W3_BANK_SHA256, "w0": w0_identity("train"), "render_code_sha256": code_sha,
            "w3_code_sha256": w3_code_sha256()}


def _sha(obj) -> str:
    import hashlib

    return hashlib.sha256(json.dumps(obj, sort_keys=True).encode()).hexdigest()


def audio_sha256(audio: np.ndarray) -> str:
    import hashlib

    return hashlib.sha256(np.ascontiguousarray(audio, dtype=np.float32).tobytes()).hexdigest()


def prepare_render_dir(out: Path, ident: dict, keys: Sequence[str]) -> list[str]:
    """Bind the render directory to `ident`: refuse another identity, renders
    without an identity, or unexpected files; return the keys still to render."""
    d = out / "mix"
    d.mkdir(parents=True, exist_ok=True)
    ipath = out / "render_identity.json"
    if ipath.exists():
        from .identities import differing, same

        stored = json.loads(ipath.read_text())
        if not same(stored, ident):
            raise RuntimeError(f"{out} holds renders of another identity (differs in {differing(stored, ident)}); "
                               "refusing to reuse or mix them")
    else:
        if any(d.glob("*.npz")) or (out / "render.json").exists():
            raise RuntimeError(f"{d} holds renders without an identity; refusing")
        ipath.write_text(json.dumps(ident, indent=1))
    extra = sorted({p.stem for p in d.glob("*.npz")} - set(keys))
    if extra:
        raise RuntimeError(f"unexpected renders {extra[:3]}")
    return [k for k in keys if not (d / f"{k}.npz").exists()]


def render(workers: int, n_per: int = N_PER_FAMILY, out: Path = OUT) -> None:
    from multiprocessing import get_context

    d = out / "mix"
    keys = expected_keys(n_per)
    ident = render_identity(n_per)
    todo = prepare_render_dir(out, ident, keys)
    jobs = [(k.split("-")[0], int(k.split("-")[1]), str(d)) for k in todo]
    t0 = time.time()
    with get_context("spawn").Pool(workers) as p:
        for k, key in enumerate(p.imap_unordered(_render_one, jobs, chunksize=2)):
            if (k + 1) % 50 == 0:
                print(json.dumps({"rendered": k + 1, "of": len(jobs), "elapsed_s": round(time.time() - t0, 1)}), flush=True)
    have = sorted(p.stem for p in d.glob("*.npz"))
    if have != sorted(keys):
        raise RuntimeError("renders do not match the expected keys")
    # bind the manifest to the PERSISTED identity: a resume accepted under a docs-only W0 commit
    # keeps render_identity.json unchanged (sol stepbudget-r2 #1)
    manifest = {"identity_sha256": _sha(persisted_identity(out)), "keys": {k: audio_sha256(load_mix(d / f"{k}.npz")["audio"]) for k in keys}}
    (out / "render.json").write_text(json.dumps(manifest, indent=1))


def validated_manifest(out: Path = OUT, identity_fn=None) -> dict:
    """The manifest, accepted only if the stored identity equals the identity
    the CURRENT code, seed, policy, bank and W0 would produce, and the keys
    and files are exactly the expected ones (review implI2-r2 #2). Every
    consumer (asr, report) enters through this."""
    stored = json.loads((out / "render_identity.json").read_text())
    current = (identity_fn or render_identity)(stored["n_per_family"])
    from .identities import differing, same

    if not same(stored, current):
        raise RuntimeError(f"renders were made under another identity (differs in {differing(stored, current)}); "
                           "re-render")
    man = read_manifest(out)
    keys = expected_keys(stored["n_per_family"])
    if sorted(man["keys"]) != sorted(keys) or sorted(p.stem for p in (out / "mix").glob("*.npz")) != sorted(keys):
        raise RuntimeError("renders do not match the expected keys")
    return man


def persisted_identity(out: Path) -> dict:
    return json.loads((out / "render_identity.json").read_text())


def read_manifest(out: Path = OUT) -> dict:
    """The complete render manifest, checked against its identity file."""
    m = json.loads((out / "render.json").read_text())
    if m["identity_sha256"] != _sha(json.loads((out / "render_identity.json").read_text())):
        raise RuntimeError("render manifest does not match its identity")
    return m


def load_mix(path: Path) -> dict:
    z = np.load(path, allow_pickle=False)
    return {"audio": z["audio"], "target_image": z["target_image"], "noise": z["noise"], "labels": z["labels"],
            "meta": json.loads(str(z["meta"])), "info": json.loads(str(z["info"]))}


# --- ASR (GPU) ------------------------------------------------------------------------

def oracle_mask(mix: dict, kind: str):
    """Clipped power-ratio oracle as stage A would store it (float16), u = 1."""
    import torch

    from .api import MaskOutput, feature_frames
    from .frontend import ideal_log_mask, parakeet_mel_power

    mel = parakeet_mel_power()
    y = mix["target_image"] + mix["noise"] if kind == "T2" else mix["target_image"]
    with torch.no_grad():
        pm = mel(torch.from_numpy(mix["audio"])[None])
        pt = mel(torch.from_numpy(np.ascontiguousarray(y, dtype=np.float32))[None])
        lm = ideal_log_mask(pt, pm)[0].numpy().astype(np.float16)
    return MaskOutput(lm, np.ones(feature_frames(len(mix["audio"])), np.float32))


def asr(device: str, out: Path = OUT, batch_size: int = 16) -> None:
    import torch

    from lfspk.harness.asr import cache_identity, load_model, transcribe

    from .api import InferenceConfig, MaskOutput, feature_frames
    from .nemo_hook import transcribe_masked

    manifest = validated_manifest(out)
    keys = list(manifest["keys"])
    a_dir = out / "asr"
    a_dir.mkdir(exist_ok=True)
    model = load_model(device)
    ident = {**cache_identity(), "device": device, "torch": torch.__version__,
             "render_identity_sha256": manifest["identity_sha256"]}
    c1 = InferenceConfig("C1")
    results = {s: {} for s in SYSTEMS}
    rng = np.random.default_rng(SHUFFLE_SEED)
    t0 = time.time()
    for s in range(0, len(keys), CHUNK):
        part = keys[s: s + CHUNK]
        mixes = {k: load_mix(out / "mix" / f"{k}.npz") for k in part}
        for k in part:
            if audio_sha256(mixes[k]["audio"]) != manifest["keys"][k]:
                raise RuntimeError(f"{k}: render differs from the manifest")
        by_len = sorted(part, key=lambda k: len(mixes[k]["audio"]))
        for name, order in (("B", by_len), ("B_shuffled", list(rng.permutation(by_len)))):
            for b in range(0, len(order), batch_size):
                ks = order[b: b + batch_size]
                for k, r in zip(ks, transcribe(model, [mixes[k]["audio"] for k in ks], batch_size=batch_size)):
                    results[name][k] = r
        zero = [MaskOutput(np.zeros((128, feature_frames(len(mixes[k]["audio"]))), np.float16),
                           np.ones(feature_frames(len(mixes[k]["audio"])), np.float32)) for k in part]
        audios = [mixes[k]["audio"] for k in part]
        for name, outs in (("Bstar", zero), ("O2", [oracle_mask(mixes[k], "T2") for k in part]),
                           ("O1", [oracle_mask(mixes[k], "T1") for k in part])):
            for k, r in zip(part, transcribe_masked(model, audios, outs, c1, batch_size=batch_size)):
                results[name][k] = r
        print(json.dumps({"done": s + len(part), "of": len(keys), "elapsed_s": round(time.time() - t0, 1)}), flush=True)
    for name, res in results.items():
        with open(a_dir / f"{name}.jsonl", "w") as f:
            for k in keys:
                f.write(json.dumps({"key": k, "audio_sha256": manifest["keys"][k], **res[k]}) + "\n")
    (a_dir / "identity.json").write_text(json.dumps(ident, indent=1))


# --- report (CPU) ---------------------------------------------------------------------

def load_transcripts(out: Path, manifest: dict) -> dict[str, dict[str, dict]]:
    """Every system's transcripts, checked against the render manifest: the same
    render generation, exactly the rendered keys, and each record's audio hash."""
    keys = list(manifest["keys"])
    aid = json.loads((out / "asr" / "identity.json").read_text())
    if aid.get("render_identity_sha256") != manifest["identity_sha256"]:
        raise RuntimeError("transcripts were made from another render generation")
    hyps = {}
    for s in SYSTEMS:
        recs_s = [json.loads(l) for l in (out / "asr" / f"{s}.jsonl").read_text().splitlines()]
        hyps[s] = {r["key"]: r for r in recs_s}
        if sorted(hyps[s]) != sorted(keys) or len(recs_s) != len(keys):
            raise RuntimeError(f"{s}: transcripts do not cover exactly the rendered keys")
        bad = [r["key"] for r in recs_s if r.get("audio_sha256") != manifest["keys"][r["key"]]]
        if bad:
            raise RuntimeError(f"{s}: transcripts of other audio for {bad[:3]}")
    return hyps


def involved_speakers(info: dict) -> tuple[str, ...]:
    """Every speaker role of an example (W0's all-role bootstrap): the rendered
    target and the interferers still audible (N lists none; implI2-r1 #2), plus
    the conditioning identity when the target is absent (implI2-r2 #4)."""
    who = [str(info["speaker"]), *[str(x) for x in info["interferers"]]]
    if info.get("absent") and info.get("impostor"):
        who.append(str(info["impostor"]))
    return tuple(dict.fromkeys(who))


def build_records(out: Path = OUT):
    from lfspk.harness.corpora import Corpus
    from lfspk.harness.refs import placed_words

    from lfspk.harness.tmetrics import unreachable

    from .evalwords import MixRecord, tokens

    corpus = Corpus("train")
    manifest = validated_manifest(out)
    keys = list(manifest["keys"])
    hyps = load_transcripts(out, manifest)
    recs = []
    for k in keys:
        mix = load_mix(out / "mix" / f"{k}.npz")
        if audio_sha256(mix["audio"]) != manifest["keys"][k]:
            raise RuntimeError(f"{k}: render differs from the manifest")
        meta, labels = mix["meta"], mix["labels"]
        F = labels.size
        tref = placed_words(corpus, meta["target"]["placements"], F, min_inside=0.0)
        irefs = [placed_words(corpus, it["placements"], F) for it in meta.get("interferers", [])]
        spk = involved_speakers(mix["info"])
        rec = MixRecord(k, mix["info"]["family"], spk, tref, irefs, labels)
        for s in SYSTEMS:
            rec.hyps[s] = tokens(hyps[s][k]["words"])
            rec.evaluate(s)
        rec.unreachable = unreachable(rec.hyps["B"], tref)
        recs.append(rec)
    return recs


def guard_shares(out: Path = OUT) -> dict:
    """Per family: share of valid bins with g_min P < 100 eps, and, among the
    bins where the T2 oracle mask sits at the floor, the share in that regime."""
    import torch

    from lfspk.pvad.features import LOG_GUARD

    from .api import G_MIN, LOG_G_MIN, valid_frames
    from .frontend import ideal_log_mask, parakeet_mel_power

    mel = parakeet_mel_power()
    acc = {}
    for p in sorted((out / "mix").glob("*.npz")):
        mix = load_mix(p)
        fam = mix["info"]["family"]
        m = valid_frames(len(mix["audio"]))
        with torch.no_grad():
            pm = mel(torch.from_numpy(mix["audio"])[None])[0, :, :m]
            pt = mel(torch.from_numpy(mix["target_image"] + mix["noise"])[None])[0, :, :m]
        guard = (G_MIN * pm.double() < 100 * LOG_GUARD)
        floored = ideal_log_mask(pt[None], pm[None])[0] <= LOG_G_MIN + 1e-6
        a = acc.setdefault(fam, [0, 0, 0, 0])
        a[0] += int(guard.sum()); a[1] += guard.numel(); a[2] += int((guard & floored).sum()); a[3] += int(floored.sum())
    return {f: {"bins_in_guard_regime": a[0] / a[1], "floored_bins": a[3],
                "floored_bins_in_guard_regime": (a[2] / a[3]) if a[3] else None} for f, a in acc.items()}


def _summary(C: np.ndarray, mask: np.ndarray) -> dict:
    """tmetrics statistics of the masked mixtures (pooled, all regions and by region)."""
    from lfspk.harness import tmetrics as tm

    return {k: (float(v) if np.ndim(v) == 0 else v) for k, v in tm.summarize(tm.weighted_totals(C, np.ones(len(C)), mask)).items()}


def report(out: Path = OUT, n_boot: int = 2000) -> dict:
    """Stage-0 metrics through the shared definitions (lfspk.harness.tmetrics)."""
    from lfspk.harness import tmetrics as tm

    from .evalwords import boot_weights, count_matrix, filter_steps, filtered, oracle_scores, token_means

    recs = build_records(out)
    # W_o: oracle word filter on B; tau = the largest attainable threshold whose pooled re-aligned
    # gross L+ is at most 0.5 % over all stage-0 examples (tmetrics.search_tau, budget_rule)
    means = [token_means(r.hyps["B"], oracle_scores(r.labels)) for r in recs]
    steps = [filter_steps(r, m) for r, m in zip(recs, means)]
    tau, _, tot = tm.search_tau(steps, np.ones(len(recs)), tm.budget_rule(0.005))
    if tau is None:
        raise RuntimeError("no oracle word-filter threshold fits the budget (keep-everything always should)")
    for r, m in zip(recs, means):
        r.hyps["W_o"] = filtered(r.hyps["B"], m, tau)
        r.evaluate("W_o")
    systems = ("B", "B_shuffled", "Bstar", "O2", "O1", "W_o")
    fam = np.array([r.family for r in recs])
    interf = [f for f in FAMILIES if f.startswith("S") and f != "S0"]
    masks = {f: fam == f for f in FAMILIES}
    masks["S1-S4"] = np.isin(fam, interf)
    masks["all"] = np.ones(len(recs), bool)
    C = {s: count_matrix(recs, s) for s in systems}
    res: dict = {"n_mixtures": len(recs), "speakers": len({x for r in recs for x in r.speakers}),
                 "W_o_tau": tau, "W_o_Lplus": tm.summarize(tot)["L+/all"], "groups": {}}
    for g, m in masks.items():
        res["groups"][g] = {s: _summary(C[s], m) for s in systems}
    # transcripts changed (diagnostics: parity and baseline batching sensitivity)
    for s in ("B_shuffled", "Bstar"):
        for f in FAMILIES:
            sel = [r for r in recs if r.family == f]
            res["groups"][f][s]["changed_transcripts"] = float(np.mean(
                [[w.text for w in r.hyps[s]] != [w.text for w in r.hyps["B"]] for r in sel]))
    # stop rule (pre-registered)
    W = boot_weights(recs, n_boot)
    r_o2 = res["groups"]["S1-S4"]["O2"]["R/all"]
    r_wo = res["groups"]["S1-S4"]["W_o"]["R/all"]
    lp = res["groups"]["all"]["O2"]["L+/all"]
    lp_boot = tm.summarize(tm.weighted_totals(C["O2"], W))["L+/all"]
    lo, hi = tm.ci(lp_boot, 0.95)
    stop_a = bool(r_o2 >= r_wo)
    stop_b = bool(lp > 0.010 and lo > 0.005)
    res["stop_rule"] = {"R_O2_S1-S4": r_o2, "R_Wo_S1-S4": r_wo, "a_triggered": stop_a, "L+_O2_all": lp,
                        "L+_O2_all_ci95": [lo, hi], "valid_resamples": int(np.isfinite(lp_boot).sum()),
                        "b_triggered": stop_b, "stop": stop_a or stop_b}
    # parity diagnostic (9.0): fix W5's path first if B* differs from B on more than 1 % of
    # transcripts or by more than 0.05 WER points in any family
    parity = {f: {"changed": res["groups"][f]["Bstar"]["changed_transcripts"],
                  "dWER": res["groups"][f]["Bstar"]["dWER/all"]} for f in FAMILIES}
    res["parity"] = parity
    res["parity_fix_needed"] = bool(any(v["changed"] > 0.01 or abs(v["dWER"]) > 0.0005 for v in parity.values()))
    res["guard"] = guard_shares(out)
    (out / "report.json").write_text(json.dumps(res, indent=1, default=float))
    return res


def main(argv: Sequence[str] | None = None) -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    r = sub.add_parser("render")
    r.add_argument("--workers", type=int, default=6)
    r.add_argument("--n", type=int, default=N_PER_FAMILY)
    r.add_argument("--out", type=Path, default=OUT)
    a = sub.add_parser("asr")
    a.add_argument("--device", default="cuda")
    a.add_argument("--out", type=Path, default=OUT)
    p = sub.add_parser("report")
    p.add_argument("--out", type=Path, default=OUT)
    p.add_argument("--n-boot", type=int, default=2000)
    args = ap.parse_args(argv)
    if args.cmd == "render":
        render(args.workers, args.n, args.out)
    elif args.cmd == "asr":
        if args.device.startswith("cuda") and "AGENT_JOBS_VRAM_FRACTION" in os.environ:
            import torch

            torch.cuda.set_per_process_memory_fraction(float(os.environ["AGENT_JOBS_VRAM_FRACTION"]))
        asr(args.device, args.out)
    else:
        print(json.dumps(report(args.out, args.n_boot)["stop_rule"], indent=1))


if __name__ == "__main__":
    main()
