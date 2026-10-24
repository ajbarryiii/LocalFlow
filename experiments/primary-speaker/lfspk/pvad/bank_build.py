"""Precompute the training enrollment bank (DESIGN.md section 5).

    ./python -m lfspk.pvad.bank_build --embedder ecapa-vox --workers 8 [--device cuda]

For every target-eligible train speaker (enrollment.target_eligible) and each
of its bank utterances (enrollment.bank_utterances: up to 40 from the
enrollment pool), and for each device in W0's `channels.DEVICES`, W0 renders
the utterance as a dictation twice in one call, `render_paired(("S0", "S4"))`:
clean (room noise only) and contaminated (an S4-like second talker), sharing
the target and noise bit-exactly, as the harness's enrollment streams do. Both
are embedded with W1's frozen embedder. Rendering runs in CPU worker processes;
embedding runs in this process.

Output under RUNS/W3/emb/<embedder>/: parts/part-NNNN.npz (resumable shards of
`SHARD` speakers), then bank.npz (an EnrollmentBank) and bank_meta.json. Nothing
here touches the dev or test splits.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import time
from multiprocessing import get_context
from pathlib import Path

import numpy as np

from lfspk import paths

from .enrollment import EnrollmentBank, bank_utterances, librispeech_partitions, target_eligible
from .identity import REPO as REPO_ROOT
from .identity import require_same, w0_identity
from .train import git_commit

SHARD = 25
PER_SPEAKER = 40
OUT = paths.RUNS / "W3" / "emb"


def render_seed(utt: str, device: str) -> int:
    return int(hashlib.sha256(f"w3-bank/{utt}/{device}".encode()).hexdigest()[:15], 16)


def work_items(per_speaker: int = PER_SPEAKER) -> list[tuple[str, list[str]]]:
    """[(speaker, bank utterances)] for every target-eligible train speaker, sorted."""
    parts = librispeech_partitions("train")
    return [(s, bank_utterances(p, per_speaker)) for s, p in sorted(parts.items(), key=lambda kv: int(kv[0]))
            if target_eligible(p)]


_GEN = None


def _render(args: tuple[str, str, str]) -> tuple[str, str, str, np.ndarray, np.ndarray, dict]:
    """(speaker, utt, device) -> clean and contaminated dictation audio."""
    global _GEN
    if _GEN is None:
        from lfspk.harness.mix import MixtureGenerator

        _GEN = MixtureGenerator("train")
    spk, utt, device = args
    pair = _GEN.render_paired(("S0", "S4"), render_seed(utt, device), target=utt, device=device, rir_mode="coherent")
    c, d = pair["S0"], pair["S4"]
    if c.meta["target"]["utt"] != utt or d.meta["target"]["utt"] != utt:
        raise AssertionError("W0 rendered a different target")
    info = {"index_hashes": c.meta["index_hashes"],
            "contaminator": [i.get("speaker") for i in d.meta.get("interferers", [])]}
    return spk, utt, device, c.audio, d.audio, info


SEED_RULE = "w3-bank-v1: int(sha256('w3-bank/<utt>/<device>')[:15], 16)"
RENDER = "MixtureGenerator('train').render_paired(('S0','S4'), seed, target=utt, device, rir_mode='coherent')"
IGNORED = ("w0_commit",)  # recorded, not compared: the code hash is the identity


def bank_identity(embedder: str, embedder_sha256: str, devices, w0: dict, selected_by: str = "") -> dict:
    """Everything a shard's content depends on. Shards are reused only when equal."""
    w3 = REPO_ROOT / "lfspk" / "pvad"
    return {"kind": "w3-enrollment-bank", "embedder": embedder, "weights_sha256": embedder_sha256,
            "embedder_selected_by": selected_by,
            "per_speaker": PER_SPEAKER, "shard_size": SHARD, "devices": list(devices), "seed_rule": SEED_RULE,
            "render": RENDER, "w3_bank_code_sha256": file_sha256s(w3 / "bank_build.py", w3 / "enrollment.py"), **w0}


def file_sha256s(*files: Path) -> str:
    h = hashlib.sha256()
    for f in files:
        h.update(f.name.encode() + b" " + hashlib.sha256(f.read_bytes()).hexdigest().encode() + b"\n")
    return h.hexdigest()


def shard_identity(identity: dict, shard: list[tuple[str, list[str]]]) -> dict:
    return {**identity, "shard_speakers": [s for s, _ in shard],
            "shard_items_sha256": hashlib.sha256(json.dumps(shard).encode()).hexdigest()}


def read_shard_identity(path: Path) -> dict:
    with np.load(path, allow_pickle=False) as z:
        if "identity" not in z.files:
            return {}
        return json.loads(str(z["identity"]))


def build(embedder_name: str, workers: int, device: str, out_root: Path = OUT, limit_speakers: int | None = None,
          selected_by: str = "") -> Path:
    from lfspk.embed.embedder import load_embedder
    from lfspk.harness.channels import DEVICES

    if device.startswith("cuda") and "AGENT_JOBS_VRAM_FRACTION" in os.environ:
        import torch

        torch.cuda.set_per_process_memory_fraction(float(os.environ["AGENT_JOBS_VRAM_FRACTION"]))
    out = out_root / embedder_name
    (out / "parts").mkdir(parents=True, exist_ok=True)
    emb = load_embedder(embedder_name, device)
    identity = bank_identity(emb.name, emb.weights_sha256, DEVICES, w0_identity("train"), selected_by)
    items = work_items()
    if limit_speakers is not None:
        items = items[:limit_speakers]
    shards = [items[i: i + SHARD] for i in range(0, len(items), SHARD)]
    t0 = time.time()
    ctx = get_context("spawn")
    with ctx.Pool(workers) as pool:
        for si, shard in enumerate(shards):
            path = out / "parts" / f"part-{si:04d}.npz"
            want = shard_identity(identity, shard)
            if path.exists():
                require_same(read_shard_identity(path), want, f"bank shard {path.name}", IGNORED)
                continue
            jobs = [(s, u, dev) for s, utts in shard for u in utts for dev in DEVICES]
            rows, spk, utt, ch, cont, contam_spk = [], [], [], [], [], []
            batch_audio: list[np.ndarray] = []

            def flush():
                if batch_audio:
                    rows.extend(emb.embed_batch(batch_audio))
                    batch_audio.clear()

            for s, u, dev, clean, dirty, info in pool.imap(_render, jobs, chunksize=4):
                if info["index_hashes"] != identity["w0_index_hashes"]:
                    raise RuntimeError("a render worker sees different W0 corpus indexes than the build identity")
                for audio, is_cont in ((clean, False), (dirty, True)):
                    batch_audio.append(audio)
                    spk.append(s), utt.append(u), ch.append(dev), cont.append(is_cont)
                    contam_spk.append(",".join(str(x) for x in info["contaminator"]) if is_cont else "")
                if len(batch_audio) >= 64:
                    flush()
            flush()
            # W0's code must not have changed while this shard rendered (workers import it once)
            require_same(identity, bank_identity(emb.name, emb.weights_sha256, DEVICES, w0_identity("train"), selected_by),
                         "a shard rendered across a W0 or W3 code change", IGNORED)
            arr = np.asarray(rows, dtype=np.float32)
            if arr.shape[0] != len(spk):
                raise AssertionError("embedding count mismatch")
            tmp = path.with_suffix(".tmp.npz")
            np.savez(tmp, emb=arr, speaker=np.array(spk), utt=np.array(utt), channel=np.array(ch),
                     contaminated=np.array(cont), contaminator=np.array(contam_spk), identity=np.array(json.dumps(want)))
            os.replace(tmp, path)
            print(json.dumps({"shard": si, "of": len(shards), "rows": len(spk), "elapsed_s": round(time.time() - t0, 1)}),
                  flush=True)
    partitions = librispeech_partitions("train")
    return merge(out, identity, getattr(emb, "params", None), items, {s: partitions[s] for s, _ in items}, shards)


def merge(out: Path, identity: dict, embedder_params, items, partitions, shards) -> Path:
    """Concatenate exactly the expected shards, each with the build identity, then
    check pools, variant coverage, row count and unit norms, and write bank.npz
    and bank_meta.json (provenance taken from the identity)."""
    devices = identity["devices"]
    paths_ = [out / "parts" / f"part-{si:04d}.npz" for si in range(len(shards))]
    extra = sorted(set((out / "parts").glob("part-*.npz")) - set(paths_))
    if extra:
        raise ValueError(f"unexpected shards in {out / 'parts'}: {[p.name for p in extra][:3]}")
    for p, shard in zip(paths_, shards):
        require_same(read_shard_identity(p), shard_identity(identity, shard), f"bank shard {p.name}", IGNORED)
    zs = [np.load(p, allow_pickle=False) for p in paths_]
    bank = EnrollmentBank(np.concatenate([z["emb"] for z in zs]), np.concatenate([z["speaker"] for z in zs]),
                          np.concatenate([z["utt"] for z in zs]), np.concatenate([z["channel"] for z in zs]),
                          np.concatenate([z["contaminated"] for z in zs]), identity["embedder"], identity["weights_sha256"])
    bank.check(partitions, devices)
    if set(bank.speakers()) != {s for s, _ in items}:
        raise AssertionError("bank speakers differ from the work items")
    expected = sum(len(u) for _, u in items) * len(devices) * 2
    if len(bank.emb) != expected:
        raise AssertionError(f"bank has {len(bank.emb)} rows, expected {expected}")
    norms = np.linalg.norm(bank.emb, axis=1)
    if not np.allclose(norms, 1.0, atol=1e-3):
        raise AssertionError("embeddings are not unit vectors")
    path = out / "bank.npz"
    bank.save(path)
    meta = {"identity": identity, "embedder_params": embedder_params, "dim": bank.dim, "rows": int(len(bank.emb)),
            "speakers": len(items), "git_commit": git_commit(),
            "bank_sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
            "created_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())}
    (out / "bank_meta.json").write_text(json.dumps(meta, indent=1))
    return path


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--embedder", required=True)
    ap.add_argument("--workers", type=int, default=8)
    ap.add_argument("--device", default="cuda")
    ap.add_argument("--limit-speakers", type=int, default=None, help="smoke runs only")
    ap.add_argument("--out", type=Path, default=OUT)
    ap.add_argument("--selected-by", default="", help="provenance of the embedder choice, e.g. W1 survey commit")
    a = ap.parse_args()
    paths.require_mount()
    print(build(a.embedder, a.workers, a.device, a.out, a.limit_speakers, a.selected_by))


if __name__ == "__main__":
    main()
