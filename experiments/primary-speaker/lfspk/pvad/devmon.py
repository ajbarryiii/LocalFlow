"""Frame-level dev monitor set (DESIGN.md section 7): logged during training,
never used for a choice.

    ./python -m lfspk.pvad.devmon build --set-id <W0 dev set> --embedder ecapa-vox

Picks up to `per_scenario` coherent-room mixtures per scenario from W0's frozen
dev set (stable sha256 order of mixture ids, at most `per_speaker` per target
speaker and scenario), and for each target speaker a profile from its first 10
clean built-in enrollment dictations (the harness headline condition), embedded
with W1's embedder; speakers with fewer than 10 such dictations are left out
(listed in `excluded_short`). Only dev sets are accepted (`check_dev`), checked
before any audio is read. Stores references and profiles only; audio and labels are
read from the frozen set. Output: RUNS/W3/devmon/<set_id>-<embedder>.npz.
"""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path

import numpy as np

from lfspk import paths

from .data import Mixture
from .enrollment import mean_profile
from .w0_source import interferer_speakers

OUT = paths.RUNS / "W3" / "devmon"
K_ENROLL = 10


def _h(s: str) -> str:
    return hashlib.sha256(s.encode()).hexdigest()


def check_dev(manifest: list[dict], dev_speakers: set[str] | None = None) -> None:
    """Refuse anything but a dev set, before any audio is read: every row's
    rendered split must be "dev" and every target a dev speaker."""
    if dev_speakers is None:
        from lfspk import splits

        dev_speakers = {s.id for s in splits.speakers("dev")}
    if not manifest:
        raise ValueError("empty manifest")
    bad = [r.get("id") for r in manifest if (r.get("meta") or {}).get("split") != "dev"]
    if bad:
        raise ValueError(f"not a dev set: rows {bad[:3]} are not rendered from the dev split")
    foreign = sorted({str(r["speaker"]) for r in manifest} - set(dev_speakers))
    if foreign:
        raise ValueError(f"not a dev set: speakers {foreign[:3]} are not dev speakers")


def select(manifest: list[dict], per_scenario: int = 60, per_speaker: int = 2) -> list[dict]:
    out = []
    for sc in ("S0", "S1", "S2", "S3", "S4"):
        rows = sorted((r for r in manifest if r["scenario"] == sc and r.get("rir_mode", "coherent") == "coherent"),
                      key=lambda r: _h(r["id"]))
        count: dict[str, int] = {}
        for r in rows:
            if len([x for x in out if x["scenario"] == sc]) >= per_scenario:
                break
            if count.get(r["speaker"], 0) >= per_speaker:
                continue
            count[r["speaker"]] = count.get(r["speaker"], 0) + 1
            out.append(r)
    return out


def build(set_id: str, embedder_name: str, device: str = "cpu", per_scenario: int = 60) -> Path:
    from lfspk.embed.embedder import load_embedder
    from lfspk.harness.frozen import FrozenSet

    fs = FrozenSet(set_id)
    check_dev(fs.manifest)
    emb = load_embedder(embedder_name, device)
    # speakers whose clean built-in stream has fewer than K_ENROLL dictations are
    # left out, so every profile really is the (10, clean, built-in) condition
    full = {str(s) for s in {r["speaker"] for r in fs.manifest}
            if len(fs.enrollment_stream(str(s), "builtin", contaminated=False)) >= K_ENROLL}
    excluded = sorted({str(r["speaker"]) for r in fs.manifest} - full, key=int)
    rows = select([r for r in fs.manifest if str(r["speaker"]) in full], per_scenario)
    profiles = {}
    for spk in sorted({str(r["speaker"]) for r in rows}, key=int):
        stream = fs.enrollment_stream(spk, "builtin", contaminated=False)[:K_ENROLL]
        profiles[spk] = mean_profile(emb.embed_batch([fs.audio(r["file"]) for r in stream]))
    OUT.mkdir(parents=True, exist_ok=True)
    path = OUT / f"{set_id}-{embedder_name}.npz"
    np.savez(path, ids=np.array([r["id"] for r in rows]), speakers=np.array(sorted(profiles, key=int)),
             profiles=np.stack([profiles[s] for s in sorted(profiles, key=int)]), set_id=np.array(set_id),
             set_hash=np.array(fs.hash), embedder=np.array(emb.name), embedder_sha256=np.array(emb.weights_sha256),
             k_enroll=np.array(K_ENROLL), excluded_short=np.array(excluded))
    return path


def load(path: Path) -> list[tuple[Mixture, np.ndarray]]:
    """[(Mixture, profile)] for train.evaluate_frames."""
    from lfspk.harness.frozen import FrozenSet

    z = np.load(path, allow_pickle=False)
    fs = FrozenSet(str(z["set_id"]))
    if fs.hash != str(z["set_hash"]):
        raise ValueError("frozen set changed since the monitor was built")
    check_dev(fs.manifest)
    prof = dict(zip([str(s) for s in z["speakers"].tolist()], z["profiles"]))
    by_id = {r["id"]: r for r in fs.manifest}
    items = []
    for mid in z["ids"].tolist():
        r = by_id[mid]
        audio = fs.audio(r["files"]["mix"]).astype(np.float32)
        labels = fs.labels(r)["labels"]
        spk = str(r["speaker"])
        if spk not in prof:
            raise ValueError(f"monitor row {mid} has no profile")
        speakers = (spk,) + tuple(s for s in interferer_speakers(r["meta"]) if s != spk)
        mix = Mixture(audio, labels, spk, (r["meta"]["target"]["utt"],), speakers, r["scenario"], "builtin", {"id": mid})
        items.append((mix, prof[spk].astype(np.float32)))
    return items


def main() -> None:
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    b = sub.add_parser("build")
    b.add_argument("--set-id", required=True)
    b.add_argument("--embedder", required=True)
    b.add_argument("--device", default="cpu")
    b.add_argument("--per-scenario", type=int, default=60)
    a = ap.parse_args()
    print(json.dumps({"path": str(build(a.set_id, a.embedder, a.device, a.per_scenario))}))


if __name__ == "__main__":
    main()
