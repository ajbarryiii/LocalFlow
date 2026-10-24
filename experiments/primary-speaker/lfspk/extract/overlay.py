"""Contaminator audit and overlay of W3's enrollment bank (DESIGN section 8; review r1 #7).

W3's bank (`runs/W3/emb/redimnet2-b2/bank.npz`) holds, per bank utterance and
device, a clean dictation and a contaminated twin (an S4-like second talker).
Its shards record each contaminated row's contaminating speakers. A held-out
speaker's voice must not reach W5's training through those twins, so:

    ./python -m lfspk.extract.overlay audit [--scope train|heldout]     # counts only, CPU, seconds
    ./python -m lfspk.extract.overlay build --workers 6 --device cuda [--scope train|heldout]

Scope "heldout" (implT-r1 #5) re-renders every contaminated twin of the
held-out speakers with a held-out-only contaminator pool, so that the held-out
monitor's contaminated profiles never contain a training speaker's voice.

`build` re-renders exactly the affected rows, with the same utterance, device
and W3 seed rule, by `MixtureGenerator("train", speakers=<train minus
held-out>).render_paired(("S0", "S4"), ...)`. It embeds the contaminated twin
with the same redimnet2-b2 weights, checks that the new contaminators are
outside the held-out set, and writes `runs/W5/bank/redimnet2-b2/overlay.npz`
with an identity record. `load_bank()` returns W3's bank with those rows
replaced, after verifying both files.
"""

from __future__ import annotations

import argparse
import hashlib
import io
import json
import os
import time
from pathlib import Path
from typing import Mapping, Sequence

import numpy as np

from lfspk import paths
from lfspk.pvad.enrollment import EnrollmentBank

EMBEDDER = "redimnet2-b2"
W3_DIR = paths.RUNS / "W3" / "emb" / EMBEDDER
OUT_DIR = paths.RUNS / "W5" / "bank" / EMBEDDER
W3_BANK_SHA256 = "b34c8b688d6f71abc00488b8513746bd744dca6b916f12c422c0b6de843a1801"


def read_verified(path: Path, sha256: str) -> bytes:
    raw = Path(path).read_bytes()
    got = hashlib.sha256(raw).hexdigest()
    if got != sha256:
        raise ValueError(f"{path}: SHA-256 {got} != {sha256}")
    return raw


def load_w3_bank(w3_dir: Path = W3_DIR, sha256: str = W3_BANK_SHA256) -> tuple[EnrollmentBank, dict]:
    """W3's bank, verified against bank_meta.json and the pinned hash."""
    meta = json.loads((w3_dir / "bank_meta.json").read_text())
    if meta["bank_sha256"] != sha256:
        raise ValueError("bank_meta.json names another bank than the one W5 pins")
    z = np.load(io.BytesIO(read_verified(w3_dir / "bank.npz", sha256)), allow_pickle=False)
    bank = EnrollmentBank(emb=z["emb"], speaker=z["speaker"], utt=z["utt"], channel=z["channel"],
                          contaminated=z["contaminated"], embedder=str(z["embedder"]),
                          embedder_sha256=str(z["embedder_sha256"]))
    return bank, meta


def contaminator_table(w3_dir: Path, meta: dict) -> dict[tuple[str, str, str], tuple[str, ...]]:
    """(speaker, utt, channel) -> contaminating speakers of the contaminated twin,
    from W3's shards, each checked to carry the bank's build identity."""
    out: dict[tuple[str, str, str], tuple[str, ...]] = {}
    ident = meta["identity"]
    for p in sorted((w3_dir / "parts").glob("part-*.npz")):
        with np.load(p, allow_pickle=False) as z:
            sid = json.loads(str(z["identity"]))
            for k, v in ident.items():
                if k != "w0_commit" and sid.get(k) != v:
                    raise ValueError(f"{p.name}: shard identity field {k} differs from the bank's")
            for s, u, ch, c, who in zip(z["speaker"], z["utt"], z["channel"], z["contaminated"], z["contaminator"]):
                if bool(c):
                    key = (str(s), str(u), str(ch))
                    if key in out:
                        raise ValueError(f"duplicate contaminated row {key}")
                    out[key] = tuple(x for x in str(who).split(",") if x)
    return out


SCOPES = ("train", "heldout")


def audit(bank: EnrollmentBank, table: Mapping[tuple[str, str, str], tuple[str, ...]],
          held_out: Sequence[str], scope: str = "train") -> list[dict]:
    """Contaminated bank rows to re-render. scope "train": rows whose
    contaminator is a held-out speaker (W5 training). scope "heldout": every
    contaminated row of a held-out speaker, so that held-out-only uses (the
    monitor) never see a training speaker's voice (implT-r1 #5)."""
    if scope not in SCOPES:
        raise ValueError(f"scope must be one of {SCOPES}")
    held = set(held_out)
    rows = []
    n_cont = 0
    for i in range(len(bank.emb)):
        if not bool(bank.contaminated[i]):
            continue
        n_cont += 1
        key = (str(bank.speaker[i]), str(bank.utt[i]), str(bank.channel[i]))
        if key not in table:
            raise ValueError(f"contaminated row {key} has no contaminator record")
        who = table[key]
        if not who:
            raise ValueError(f"contaminated row {key} records no contaminator")
        hit = bool(set(who) & held) if scope == "train" else key[0] in held
        if hit:
            rows.append({"row": i, "speaker": key[0], "utt": key[1], "channel": key[2], "contaminators": list(who)})
    if n_cont != len(table):
        raise ValueError(f"bank has {n_cont} contaminated rows, shards record {len(table)}")
    return rows


def overlay_identity(meta: dict, held_out: Sequence[str], rows: Sequence[dict], w0_now: dict, scope: str = "train") -> dict:
    ident = meta["identity"]
    pool = "<train minus held-out>" if scope == "train" else "<held-out only>"
    return {"kind": "w5-bank-overlay", "scope": scope, "w3_bank_sha256": meta["bank_sha256"], "embedder": ident["embedder"],
            "weights_sha256": ident["weights_sha256"], "seed_rule": ident["seed_rule"],
            "render": f"MixtureGenerator('train', speakers={pool}).render_paired(('S0','S4'), seed, "
                      "target=utt, device, rir_mode='coherent'); the S4 twin replaces the contaminated row",
            "held_out_sha256": hashlib.sha256(",".join(sorted(held_out, key=int)).encode()).hexdigest(),
            "rows_sha256": hashlib.sha256(json.dumps([r["row"] for r in rows]).encode()).hexdigest(),
            "n_rows": len(rows), "w0_code_sha256": w0_now.get("w0_code_sha256"),
            "w0_index_hashes": w0_now.get("w0_index_hashes"),
            "w0_code_matches_bank": w0_now.get("w0_code_sha256") == ident.get("w0_code_sha256"),
            "w0_index_matches_bank": w0_now.get("w0_index_hashes") == ident.get("w0_index_hashes")}


def apply_overlay(bank: EnrollmentBank, rows: np.ndarray, emb: np.ndarray) -> EnrollmentBank:
    """A copy of `bank` with emb[rows] replaced; every replaced row must be a contaminated one."""
    rows = np.asarray(rows, dtype=np.int64)
    if len(np.unique(rows)) != len(rows):
        raise ValueError("duplicate overlay rows")
    if len(rows) and not bool(np.all(bank.contaminated[rows])):
        raise ValueError("the overlay replaces a clean row")
    e = np.array(bank.emb, dtype=np.float32, copy=True)
    if emb.shape != (len(rows), e.shape[1]):
        raise ValueError("overlay embeddings have the wrong shape")
    if len(rows) and not np.allclose(np.linalg.norm(emb, axis=1), 1.0, atol=1e-3):
        raise ValueError("overlay embeddings are not unit vectors")
    e[rows] = emb
    return EnrollmentBank(e, bank.speaker, bank.utt, bank.channel, bank.contaminated, bank.embedder, bank.embedder_sha256)


def held_out() -> tuple[str, ...]:
    from lfspk.pvad.enrollment import librispeech_partitions

    from .data import held_out_speakers, train_sex

    return held_out_speakers(librispeech_partitions("train"), train_sex())


def overlay_name(scope: str) -> str:
    return "overlay" if scope == "train" else f"overlay_{scope}"


def load_bank(out_dir: Path = OUT_DIR, w3_dir: Path = W3_DIR, scope: str = "train") -> tuple[EnrollmentBank, dict]:
    """W3's bank with one W5 overlay applied: "train" for training, "heldout" for
    held-out-only uses. Refuses an overlay built for another bank, scope or
    held-out set; for "heldout", also checks that every contaminated row of
    every held-out speaker was replaced by a twin whose contaminators are all
    held-out speakers."""
    bank, meta = load_w3_bank(w3_dir)
    name = overlay_name(scope)
    ov_meta = json.loads((out_dir / f"{name}_meta.json").read_text())
    z = np.load(io.BytesIO(read_verified(out_dir / f"{name}.npz", ov_meta["overlay_sha256"])), allow_pickle=False)
    ident = json.loads(str(z["identity"]))
    if ident != ov_meta["identity"] or ident["w3_bank_sha256"] != meta["bank_sha256"] or ident.get("scope", "train") != scope:
        raise ValueError("overlay identity does not match its meta, the W3 bank or the scope")
    held = held_out()
    want = hashlib.sha256(",".join(sorted(held, key=int)).encode()).hexdigest()
    if ident["held_out_sha256"] != want:
        raise ValueError("overlay was built for another held-out set")
    rows = z["rows"]
    if scope == "heldout":
        hs = set(held)
        need = {i for i in range(len(bank.emb)) if bool(bank.contaminated[i]) and str(bank.speaker[i]) in hs}
        if set(int(r) for r in rows) != need:
            raise ValueError("held-out overlay does not cover exactly the held-out speakers' contaminated rows")
        for who in z["contaminator"]:
            ws = [x for x in str(who).split(",") if x]
            if not ws or set(ws) - hs:
                raise ValueError("a held-out overlay row has a contaminator outside the held-out set")
    return apply_overlay(bank, rows, z["emb"]), ident


_GEN = None


def _render(args: tuple[str, str, str, tuple[str, ...]]):
    global _GEN
    from lfspk.pvad.bank_build import render_seed

    spk, utt, device, pool = args
    if _GEN is None:
        from lfspk.harness.mix import MixtureGenerator

        _GEN = MixtureGenerator("train", speakers=list(pool))
    pair = _GEN.render_paired(("S0", "S4"), render_seed(utt, device), target=utt, device=device, rir_mode="coherent")
    d = pair["S4"]
    if d.meta["target"]["utt"] != utt:
        raise AssertionError("W0 rendered a different target")
    who = [str(i.get("speaker")) for i in d.meta.get("interferers", [])]
    return spk, utt, device, d.audio, who, d.meta["index_hashes"]


def build(workers: int, device: str, out_dir: Path = OUT_DIR, scope: str = "train") -> Path:
    from multiprocessing import get_context

    from lfspk import splits
    from lfspk.embed.embedder import load_embedder
    from lfspk.pvad.identity import w0_identity

    if device.startswith("cuda") and "AGENT_JOBS_VRAM_FRACTION" in os.environ:
        import torch

        torch.cuda.set_per_process_memory_fraction(float(os.environ["AGENT_JOBS_VRAM_FRACTION"]))
    bank, meta = load_w3_bank()
    held = held_out()
    rows = audit(bank, contaminator_table(W3_DIR, meta), held, scope)
    w0_now = w0_identity("train")
    ident = overlay_identity(meta, held, rows, w0_now, scope)
    print(json.dumps({"affected_rows": len(rows), "w0_code_matches_bank": ident["w0_code_matches_bank"],
                      "w0_index_matches_bank": ident["w0_index_matches_bank"]}), flush=True)
    if not ident["w0_index_matches_bank"]:
        raise RuntimeError("W0's corpus indexes changed since W3 built its bank; refusing to mix renders")
    emb = load_embedder(EMBEDDER, device)
    if emb.weights_sha256 != meta["identity"]["weights_sha256"]:
        raise RuntimeError("embedder weights differ from the bank's")
    if scope == "train":
        pool = tuple(s.id for s in splits.speakers("train") if s.id not in set(held))
    else:
        pool = tuple(sorted(held, key=int))
    jobs = [(r["speaker"], r["utt"], r["channel"], pool) for r in rows]
    new_emb, new_who = [], []
    t0 = time.time()
    with get_context("spawn").Pool(workers) as p:
        for k, (spk, utt, dev, audio, who, ih) in enumerate(p.imap(_render, jobs, chunksize=4)):
            if (spk, utt, dev) != (jobs[k][0], jobs[k][1], jobs[k][2]):
                raise AssertionError("render order changed")
            if ih != meta["identity"]["w0_index_hashes"]:
                raise RuntimeError("a render worker sees other W0 indexes than the bank")
            bad = (set(who) & set(held)) if scope == "train" else (set(who) - set(held))
            if not who or bad or spk in who:
                raise AssertionError(f"{utt}/{dev}: new contaminators {who} violate the {scope} scope")
            new_emb.append(emb.embed(audio))
            new_who.append(",".join(who))
            if (k + 1) % 200 == 0:
                print(json.dumps({"done": k + 1, "of": len(jobs), "elapsed_s": round(time.time() - t0, 1)}), flush=True)
    out_dir.mkdir(parents=True, exist_ok=True)
    arr = np.asarray(new_emb, dtype=np.float32).reshape(len(rows), bank.dim)
    name = overlay_name(scope)
    tmp = out_dir / f"{name}.tmp.npz"
    np.savez(tmp, rows=np.array([r["row"] for r in rows], dtype=np.int64), emb=arr, contaminator=np.array(new_who),
             old_contaminator=np.array([",".join(r["contaminators"]) for r in rows]), identity=np.array(json.dumps(ident)))
    os.replace(tmp, out_dir / f"{name}.npz")
    sha = hashlib.sha256((out_dir / f"{name}.npz").read_bytes()).hexdigest()
    (out_dir / f"{name}_meta.json").write_text(json.dumps({"identity": ident, "overlay_sha256": sha,
                                                           "created_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())},
                                                          indent=1))
    apply_overlay(bank, np.array([r["row"] for r in rows]), arr)  # final consistency check
    return out_dir / f"{name}.npz"


def main(argv: Sequence[str] | None = None) -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    au = sub.add_parser("audit")
    au.add_argument("--scope", choices=SCOPES, default="train")
    b = sub.add_parser("build")
    b.add_argument("--workers", type=int, default=6)
    b.add_argument("--device", default="cpu")
    b.add_argument("--scope", choices=SCOPES, default="train")
    a = ap.parse_args(argv)
    if a.cmd == "audit":
        bank, meta = load_w3_bank()
        held = held_out()
        rows = audit(bank, contaminator_table(W3_DIR, meta), held, a.scope)
        print(json.dumps({"scope": a.scope, "held_out": len(held), "contaminated_rows": int(np.sum(bank.contaminated)),
                          "affected_rows": len(rows),
                          "affected_speakers": len({r["speaker"] for r in rows})}))
    else:
        print(build(a.workers, a.device, scope=a.scope))


if __name__ == "__main__":
    main()
