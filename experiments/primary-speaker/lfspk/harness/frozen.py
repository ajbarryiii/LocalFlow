"""Frozen scenario sets: render, hash and load (DESIGN.md section 9).

    ./python -m lfspk.harness.frozen render --split dev --set-id dev-v1 [--workers 8]
    ./python -m lfspk.harness.frozen hash DIR

Layout under SETS_DIR/<set_id>/:
  manifest.jsonl     one mixture per line: id, scenario, speaker, half, target_index,
                     seed, relation_at {3,10,30}, enroll_len, files, meta
  enrollment.jsonl   one enrollment dictation per line: speaker, device, index,
                     contaminated, relation, seed, file
  plans.json         per speaker: test chapter/project, targets, enrollment, relations,
                     contaminated positions, flags, half
  mix/<id>.flac      mixture, 24-bit FLAC (decoded float32 is what scorers and ASR get)
  dry/<id>.target.flac, dry/<id>.int<k>.flac   placed dry speech tracks, 16-bit FLAC
  labels/<id>.npz    labels, target_active, interferer_actives
  enroll/<speaker>/<device>-<jj>-clean.flac and -contam.flac (contaminated positions only)
  CONTENT.sha256     sorted "sha256  relative path" of every file above
  HASH               SHA-256 of CONTENT.sha256: the set's content hash

Every mixture of a target speaker uses the same seed per target index across
S0-S4, rendered together with one shared limiter gain, so scenarios are paired
(target and noise components bit-identical except S3, which re-times the
target). Ids: `<scenario>-<speaker>-<jj>` for the primary RIR mode (coherent:
every source in the target's room) and `<scenario>m-<speaker>-<jj>` for the
secondary mode (mixed, provenance-balanced) on the first MIXED_TARGETS targets.
In the dev split, mixtures never cross dev halves (lfspk.harness.halves) and
enrollment contamination talkers come from the other half. Mixture meta pins
the SHA-256 of every input file read (`meta.sources`).
"""

from __future__ import annotations

import argparse
import hashlib
import json
import sys
from concurrent.futures import ProcessPoolExecutor
from pathlib import Path
from typing import Any

import numpy as np
import soundfile as sf

from .. import paths
from .forced import NO_MERGE_GAP_S
from .mix import SCENARIOS, MixtureGenerator, SpeakerPlan, relabel
from .util import sha256_file, stable_int

SETS_DIR = paths.DATA / "harness" / "sets"
DEVICES = ("builtin", "headset")
KS = (3, 10, 30)


def mixture_seed(set_id: str, speaker: str, j: int) -> int:
    return stable_int("frozen", set_id, speaker, j) % (2**62)


def _pool_for(split: str, speaker: str) -> tuple[str, ...] | None:
    if split != "dev":
        return None
    from .halves import dev_halves

    h = dev_halves()
    return h["A"] if speaker in h["A"] else h["B"]


_GENS: dict[tuple[str, tuple[str, ...] | None], MixtureGenerator] = {}
MIXED_TARGETS = 4  # targets per speaker also rendered with the secondary (provenance-balanced) RIR mode


def _gen(split: str, pool: tuple[str, ...] | None) -> MixtureGenerator:
    key = (split, pool)
    if key not in _GENS:
        _GENS[key] = MixtureGenerator(split, speakers=pool, pin_sources=True)
    return _GENS[key]


_TRAIN_PROJECTS: set[str] | None = None


def train_projects() -> set[str]:
    """LibriVox projects with any chapter in the train split (policy: projects
    are not held out across splits; this supports the unseen-project check)."""
    global _TRAIN_PROJECTS
    if _TRAIN_PROJECTS is None:
        c = MixtureGenerator("train").corpus
        _TRAIN_PROJECTS = {c.project(u) for us in c.utterances.values() for u in us}
    return _TRAIN_PROJECTS


def plan_record(plan: SpeakerPlan, half: str, gen: MixtureGenerator) -> dict[str, Any]:
    tp = train_projects()
    enroll_projects = sorted({gen.corpus.project(u) for u in plan.enrollment})
    return {
        "speaker": plan.speaker, "half": half, "subset": gen.corpus.subset[plan.speaker], "sex": gen.corpus.sex[plan.speaker],
        "test_chapter": plan.test_chapter, "test_project": plan.test_project,
        "test_project_in_train": plan.test_project in tp, "enroll_projects_in_train": [p for p in enroll_projects if p in tp],
        "targets": [u.id for u in plan.targets], "enrollment": [u.id for u in plan.enrollment],
        "relations": list(plan.relations), "contaminated_positions": list(plan.contaminated_positions), "flags": list(plan.flags),
    }


def _write_mixture(root: Path, mid: str, m, corpus) -> dict[str, Any]:
    files = {"mix": f"mix/{mid}.flac", "labels": f"labels/{mid}.npz", "target_dry": f"dry/{mid}.target.flac",
             "interferers_dry": [f"dry/{mid}.int{k}.flac" for k in range(len(m.interferers_dry))]}
    sf.write(root / files["mix"], m.audio, 16000, subtype="PCM_24")
    sf.write(root / files["target_dry"], np.clip(m.target_dry, -1, 1), 16000, subtype="PCM_16")
    for k, d in enumerate(m.interferers_dry):
        sf.write(root / files["interferers_dry"][k], np.clip(d, -1, 1), 16000, subtype="PCM_16")
    # Sensitivity labels (no inter-word gap merging, same 40 ms padding), from the
    # same placements; frame-level metrics are reported under both.
    lab0, _, _ = relabel(corpus, m.meta, NO_MERGE_GAP_S)
    np.savez_compressed(root / files["labels"], labels=m.labels, target_active=m.target_active,
                        interferer_actives=np.array(m.interferer_actives, dtype=bool).reshape(len(m.interferer_actives), m.labels.size),
                        labels_nomerge=lab0)
    return files


def _render_speaker(args: tuple[str, str, str, int, int]) -> dict[str, Any]:
    split, set_id, speaker, n_targets, n_enroll = args
    root = SETS_DIR / set_id
    pool = _pool_for(split, speaker)
    half = "" if pool is None else _half_name(speaker)
    gen = _gen(split, pool)
    # Contamination talkers come from the other dev half, so a contaminator is
    # never also an evaluation interferer of the same half (test: whole split).
    other = None
    if pool is not None:
        from .halves import dev_halves

        other = _gen(split, dev_halves()["B" if half == "A" else "A"])
    plan = gen.speaker_plan(speaker, n_targets=n_targets, n_enroll=n_enroll)
    rel = {str(k): (plan.relation_at(k) if len(plan.enrollment) >= k else None) for k in KS}
    mixtures = []
    for j, target in enumerate(plan.targets):
        seed = mixture_seed(set_id, speaker, j)
        modes = ("coherent", "mixed") if j < MIXED_TARGETS else ("coherent",)
        for mode in modes:
            group = gen.render_paired(SCENARIOS, seed, target=target, device="builtin", rir_mode=mode)
            for scenario in SCENARIOS:
                m = group[scenario]
                mid = f"{scenario}{'' if mode == 'coherent' else 'm'}-{speaker}-{j:02d}"
                files = _write_mixture(root, mid, m, gen.corpus)
                mixtures.append({"id": mid, "scenario": scenario, "rir_mode": mode, "speaker": speaker, "half": half, "target_index": j,
                                 "seed": seed, "relation_at": rel, "enroll_len": len(plan.enrollment), "files": files, "meta": m.meta})
    enroll = []
    eseed = stable_int("frozen-enroll", set_id) % (2**31)
    (root / "enroll" / speaker).mkdir(parents=True, exist_ok=True)
    for device in DEVICES:
        clean, dirty = gen.enrollment_streams(plan, eseed, device, contaminator=other)
        for jj, (c, d) in enumerate(zip(clean, dirty)):
            for tag, m in (("clean", c), ("contam", d)):
                if tag == "contam" and jj not in plan.contaminated_positions:
                    continue
                f = f"enroll/{speaker}/{device}-{jj:02d}-{tag}.flac"
                sf.write(root / f, m.audio, 16000, subtype="PCM_24")
                enroll.append({"speaker": speaker, "device": device, "index": jj, "contaminated": tag == "contam",
                               "relation": plan.relations[jj], "utt": plan.enrollment[jj].id, "file": f,
                               "interferer_speakers": [i.get("speaker") for i in m.meta["interferers"]],
                               "sources": m.meta.get("sources", {})})
    return {"plan": plan_record(plan, half, gen), "mixtures": mixtures, "enrollment": enroll}


def _half_name(speaker: str) -> str:
    from .halves import half_of

    return half_of(speaker)


NOISE_FAMILIES = ("noise", "music")
NOISE_SNRS = (20, 10, 5, 0)
NOISE_TARGETS = 4


def _render_noise_speaker(args: tuple[str, str, str, str, int]) -> dict[str, Any]:
    """Noise-only twin (W5 DESIGN 9.4) of a dev-v1/test-v1 speaker: the first
    NOISE_TARGETS targets, each family x SNR, seeded like the paired set's S0
    so target, room, level and device match it; the enrollment streams are
    rendered with the paired set's enrollment seed (identical to it)."""
    split, set_id, pair_id, speaker, n_enroll = args
    root = SETS_DIR / set_id
    pool = _pool_for(split, speaker)
    half = "" if pool is None else _half_name(speaker)
    gen = _gen(split, pool)
    other = None
    if pool is not None:
        from .halves import dev_halves

        other = _gen(split, dev_halves()["B" if half == "A" else "A"])
    plan = gen.speaker_plan(speaker, n_targets=10, n_enroll=n_enroll)
    rel = {str(k): (plan.relation_at(k) if len(plan.enrollment) >= k else None) for k in KS}
    specs = [{"family": f, "snr_db": float(x)} for f in NOISE_FAMILIES for x in NOISE_SNRS]
    mixtures = []
    for j, target in enumerate(plan.targets[:NOISE_TARGETS]):
        seed = mixture_seed(pair_id, speaker, j)
        for sp, m in zip(specs, gen.render_noise_group(seed, target, specs)):
            mid = f"N{sp['family'][0]}{int(sp['snr_db']):02d}-{speaker}-{j:02d}"
            files = _write_mixture(root, mid, m, gen.corpus)
            mixtures.append({"id": mid, "scenario": "N", "noise_family": sp["family"], "snr_db": sp["snr_db"], "rir_mode": "coherent",
                             "speaker": speaker, "half": half, "target_index": j, "seed": seed, "paired_with": f"{pair_id}:S0-{speaker}-{j:02d}",
                             "relation_at": rel, "enroll_len": len(plan.enrollment), "files": files, "meta": m.meta})
    enroll = []
    eseed = stable_int("frozen-enroll", pair_id) % (2**31)
    (root / "enroll" / speaker).mkdir(parents=True, exist_ok=True)
    for device in DEVICES:
        clean, dirty = gen.enrollment_streams(plan, eseed, device, contaminator=other)
        for jj, (c, d) in enumerate(zip(clean, dirty)):
            for tag, m in (("clean", c), ("contam", d)):
                if tag == "contam" and jj not in plan.contaminated_positions:
                    continue
                f = f"enroll/{speaker}/{device}-{jj:02d}-{tag}.flac"
                sf.write(root / f, m.audio, 16000, subtype="PCM_24")
                enroll.append({"speaker": speaker, "device": device, "index": jj, "contaminated": tag == "contam",
                               "relation": plan.relations[jj], "utt": plan.enrollment[jj].id, "file": f,
                               "interferer_speakers": [i.get("speaker") for i in m.meta["interferers"]], "sources": m.meta.get("sources", {})})
    return {"plan": plan_record(plan, half, gen), "mixtures": mixtures, "enrollment": enroll}


def render_noise_set(split: str, set_id: str, pair_id: str, workers: int, n_enroll: int = 30, speakers: list[str] | None = None) -> str:
    paths.require_mount()
    root = SETS_DIR / set_id
    if root.exists() and any(root.iterdir()):
        raise SystemExit(f"{root} exists; frozen sets are never overwritten")
    for d in ("mix", "dry", "labels", "enroll"):
        (root / d).mkdir(parents=True, exist_ok=True)
    spk = speakers or MixtureGenerator(split).corpus.speakers
    jobs = [(split, set_id, pair_id, s, n_enroll) for s in spk]
    results = []
    with ProcessPoolExecutor(workers) as ex:
        for k, r in enumerate(ex.map(_render_noise_speaker, jobs)):
            results.append(r)
            print(f"{k + 1}/{len(jobs)} speaker {r['plan']['speaker']}: {len(r['mixtures'])} mixtures", flush=True)
    with open(root / "manifest.jsonl", "w") as f:
        for r in results:
            for m in r["mixtures"]:
                f.write(json.dumps(m, sort_keys=True) + "\n")
    with open(root / "enrollment.jsonl", "w") as f:
        for r in results:
            for e in r["enrollment"]:
                f.write(json.dumps(e, sort_keys=True) + "\n")
    (root / "plans.json").write_text(json.dumps({"split": split, "set_id": set_id, "paired_with": pair_id, "n_targets": NOISE_TARGETS,
                                                 "n_enroll": n_enroll, "plans": [r["plan"] for r in results]}, indent=1, sort_keys=True))
    h = content_hash(root, write=True)
    print(f"set {set_id}: HASH {h}")
    return h


def content_hash(root: Path, write: bool = False) -> str:
    """SHA-256 of the sorted (file SHA-256, relative path) listing. Read-only
    unless `write` (only the freeze step writes CONTENT.sha256 and HASH; eval r3 #4)."""
    files = sorted(p for p in root.rglob("*") if p.is_file() and p.name not in ("CONTENT.sha256", "HASH"))
    lines = [f"{sha256_file(p)}  {p.relative_to(root)}" for p in files]
    listing = "\n".join(lines) + "\n"
    h = hashlib.sha256(listing.encode()).hexdigest()
    if write:
        (root / "CONTENT.sha256").write_text(listing)
        (root / "HASH").write_text(h + "\n")
    return h


def render_set(split: str, set_id: str, workers: int, n_targets: int = 10, n_enroll: int = 30, speakers: list[str] | None = None) -> str:
    paths.require_mount()
    root = SETS_DIR / set_id
    if root.exists() and any(root.iterdir()):
        raise SystemExit(f"{root} exists; frozen sets are never overwritten")
    for d in ("mix", "dry", "labels", "enroll"):
        (root / d).mkdir(parents=True, exist_ok=True)
    spk = speakers or MixtureGenerator(split).corpus.speakers
    jobs = [(split, set_id, s, n_targets, n_enroll) for s in spk]
    results = []
    with ProcessPoolExecutor(workers) as ex:
        for k, r in enumerate(ex.map(_render_speaker, jobs)):
            results.append(r)
            print(f"{k + 1}/{len(jobs)} speaker {r['plan']['speaker']}: {len(r['mixtures'])} mixtures, {len(r['enrollment'])} enrollment", flush=True)
    with open(root / "manifest.jsonl", "w") as f:
        for r in results:
            for m in r["mixtures"]:
                f.write(json.dumps(m, sort_keys=True) + "\n")
    with open(root / "enrollment.jsonl", "w") as f:
        for r in results:
            for e in r["enrollment"]:
                f.write(json.dumps(e, sort_keys=True) + "\n")
    (root / "plans.json").write_text(json.dumps({"split": split, "set_id": set_id, "n_targets": n_targets, "n_enroll": n_enroll,
                                                 "plans": [r["plan"] for r in results]}, indent=1, sort_keys=True))
    h = content_hash(root, write=True)
    print(f"set {set_id}: HASH {h}")
    return h


# --- loading ---------------------------------------------------------------------------


class FrozenSet:
    def __init__(self, set_id: str, root: Path | None = None):
        self.set_id = set_id
        self.root = root or SETS_DIR / set_id
        self.hash = (self.root / "HASH").read_text().strip()
        self.manifest = [json.loads(l) for l in (self.root / "manifest.jsonl").read_text().splitlines() if l.strip()]
        self.enrollment_rows = [json.loads(l) for l in (self.root / "enrollment.jsonl").read_text().splitlines() if l.strip()]
        self.plans = {p["speaker"]: p for p in json.loads((self.root / "plans.json").read_text())["plans"]}

    def audio(self, rel: str) -> np.ndarray:
        x, sr = sf.read(str(self.root / rel), dtype="float32")
        assert sr == 16000 and x.ndim == 1
        return x

    def labels(self, row: dict[str, Any]) -> dict[str, np.ndarray]:
        with np.load(self.root / row["files"]["labels"]) as z:
            return {k: z[k] for k in z.files}

    def enrollment_stream(self, speaker: str, device: str, contaminated: bool) -> list[dict[str, Any]]:
        """Rows in order; at a contaminated position the contaminated version
        replaces the clean one when `contaminated`."""
        rows = [r for r in self.enrollment_rows if r["speaker"] == speaker and r["device"] == device]
        clean = {r["index"]: r for r in rows if not r["contaminated"]}
        dirty = {r["index"]: r for r in rows if r["contaminated"]}
        return [dirty[i] if contaminated and i in dirty else clean[i] for i in sorted(clean)]


def main(argv: list[str] | None = None) -> None:
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    r = sub.add_parser("render")
    r.add_argument("--split", required=True, choices=["dev", "test"])
    r.add_argument("--set-id", required=True)
    r.add_argument("--workers", type=int, default=8)
    r.add_argument("--targets", type=int, default=10)
    r.add_argument("--enroll", type=int, default=30)
    r.add_argument("--speakers", default=None, help="comma-separated subset (smoke runs only)")
    rn = sub.add_parser("render-noise")
    rn.add_argument("--split", required=True, choices=["dev", "test"])
    rn.add_argument("--set-id", required=True)
    rn.add_argument("--pair", required=True, help="the paired scenario set, e.g. dev-v1")
    rn.add_argument("--workers", type=int, default=8)
    rn.add_argument("--speakers", default=None)
    h = sub.add_parser("hash")
    h.add_argument("dir", type=Path)
    a = ap.parse_args(argv)
    if a.cmd == "render-noise":
        render_noise_set(a.split, a.set_id, a.pair, a.workers, speakers=a.speakers.split(",") if a.speakers else None)
        return
    if a.cmd == "render":
        render_set(a.split, a.set_id, a.workers, a.targets, a.enroll, a.speakers.split(",") if a.speakers else None)
    else:
        print(content_hash(a.dir))  # read-only


if __name__ == "__main__":
    sys.exit(main())
