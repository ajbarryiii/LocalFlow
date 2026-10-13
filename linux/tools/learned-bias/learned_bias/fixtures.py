"""Synthetic fixtures (no real data anywhere):

- parity fixtures for the Rust forward (CONTRACT-2 §3), one file per variant:
  `parity-{V}.safetensors` = a model file (exact §3 keys and metadata) plus
  the test case under the `fx.` prefix (see CONTRACT-2 NOTES for the layout);
- synthetic prep shards in the CONTRACT-2 §4 layout, for reader and training
  tests.

    python -m learned_bias.fixtures parity --out W/fixtures
"""

import argparse
import json
import sys
from pathlib import Path

import numpy as np
import torch
from safetensors.numpy import save_file

from . import BLANK, SEED, J, V
from .features import candidate_features, g_size, trie_features
from .model import VARIANTS, BiasModel, Trie, export_tensors, model_metadata
from .trie import ROOT, BiasTrie

DURATIONS = 5


def synthetic_phrases(rng, extra=10):
    """Hand-built overlaps (failure-link overrides, a phrase that is a prefix
    of another, depth > 15, dmax > 32) plus random phrases. Token ids only."""
    phrases = [
        [5, 6, 7],
        [5, 6, 8, 9],
        [6, 7, 10],  # at state "5 6 7" the failure link reaches "6 7"
        [7, 11],
        [5, 6],  # an end with children
        [100, 101, 102, 103],
        [101, 102, 200],
        [300],
        [5, 6],  # duplicate entry
        list(range(400, 418)),  # depth 18 > 15
        list(range(500, 535)),  # 35 tokens: dmax capped at 32
    ]
    for _ in range(extra):
        n = int(rng.integers(1, 6))
        phrases.append([int(t) for t in rng.integers(0, BLANK, size=n)])
    return phrases


def trie_arrays(trie):
    token = [BLANK] + [trie.edge[s] for s in range(1, trie.states())]
    return trie_features(token, trie.parent, trie.end)


def entries_of(phrases):
    return len({tuple(p) for p in phrases})


def randomize(model, rng_t):
    """Random non-default weights: b != 0, LayerNorms not identity, gate != 0."""
    with torch.no_grad():
        for name, p in model.named_parameters():
            if name.endswith("ln.weight"):
                p.copy_(1.0 + 0.2 * torch.randn(p.shape, generator=rng_t))
            elif name.endswith("ln.bias"):
                p.copy_(0.2 * torch.randn(p.shape, generator=rng_t))
            elif name == "gate":
                p.fill_(0.7)
        final = model.l1[2] if model.variant == "L1" else model.sc[2]
        final.weight.copy_(1.5 * torch.randn(final.weight.shape, generator=rng_t))
        final.bias.fill_(0.5)


def parity_case(variant, seed=1234, decisions=24):
    """Model and test case for one variant. Returns (tensors, metadata) of
    the combined fixture file."""
    rng = np.random.default_rng(seed)
    rng_t = torch.Generator().manual_seed(seed)
    torch.manual_seed(seed)
    model = BiasModel(variant)
    randomize(model, rng_t)
    model.eval()

    phrases = synthetic_phrases(rng)
    bt = BiasTrie(phrases)
    tf = trie_arrays(bt)
    n = bt.states()
    entries = entries_of(phrases)
    gs = g_size(entries)

    # Decision states: the root, states whose candidates differ from the
    # root's (failure-link overrides), ends with children, the deepest state.
    _, offsets, _ = bt.override_table()
    with_over = [s for s in range(n) if offsets[s + 1] > offsets[s]]
    picks = [ROOT, ROOT, ROOT]
    picks += with_over[:8]
    picks += [s for s in range(1, n) if tf["is_end"][s] and bt.children[s]][:3]
    picks += [int(np.argmax(tf["depth"]))]
    while len(picks) < decisions:
        picks.append(int(rng.integers(0, n)))
    states = np.array(picks[:decisions], dtype=np.int64)

    cand_off = [0]
    cand_tok, cand_dest = [], []
    for s in states:
        c = bt.candidates(int(s))
        cand_tok += [t for t, _ in c]
        cand_dest += [d for _, d in c]
        cand_off.append(len(cand_tok))
    cand_off = np.array(cand_off, dtype=np.int64)
    cand_tok = np.array(cand_tok, dtype=np.int64)
    cand_dest = np.array(cand_dest, dtype=np.int64)
    cand_dec = np.repeat(np.arange(len(states)), np.diff(cand_off))

    z = np.maximum(rng.normal(0.3, 1.5, size=(len(states), J)), 0).astype(np.float32)
    logits = rng.normal(0.0, 3.0, size=(len(states), V + DURATIONS)).astype(np.float32)
    # Put a candidate just below the top in half the decisions, so the bonus
    # decides the argmax.
    for i in range(len(states)):
        toks = cand_tok[cand_dec == i]
        if i % 2 == 0 and len(toks):
            y = int(toks[rng.integers(0, len(toks))])
            logits[i, y] = logits[i, :V].max() - np.float32(rng.uniform(0.0, 2.0))

    # Expected output in f64 from the f32 weights and inputs.
    m64 = BiasModel(variant)
    m64.load_state_dict(model.state_dict())
    m64 = m64.double().eval()
    tr = Trie.build(tf["token"], tf["depth"], tf["parent"], tf["nf"])
    tr.nf = tr.nf.double()
    zt = torch.from_numpy(z).double()
    lt = torch.from_numpy(logits).double()
    cd, ct, cdst = (torch.from_numpy(a) for a in (cand_dec, cand_tok, cand_dest))
    with torch.no_grad():
        x = candidate_features(tr.nf, lt, cd, ct, cdst, gs)
        keys = m64.node_pass(tr)
        b = m64.bonus(keys, zt, x, cd, cdst)
    b32 = b.float()
    fused = lt[:, :V].clone()
    fused[cd, ct] += b32.double()
    argmax = fused.argmax(dim=1).numpy()  # first max wins
    top2 = fused.topk(2, dim=1).values
    gap = float((top2[:, 0] - top2[:, 1]).min())

    tensors = {k: v.numpy() for k, v in export_tensors(model).items()}
    flat = [t for p in phrases for t in p]
    poff = np.cumsum([0] + [len(p) for p in phrases])
    i32 = lambda a: np.ascontiguousarray(np.asarray(a, dtype=np.int32))  # noqa: E731
    f32 = lambda a: np.ascontiguousarray(np.asarray(a, dtype=np.float32))  # noqa: E731
    tensors.update(
        {
            "fx.phrase.tokens": i32(flat),
            "fx.phrase.offset": i32(poff),
            "fx.entries": i32([entries]),
            "fx.g_size": f32([gs]),
            "fx.trie.token": i32(tf["token"]),
            "fx.trie.parent": i32(tf["parent"]),
            "fx.trie.depth": i32(tf["depth"]),
            "fx.trie.is_end": i32(tf["is_end"]),
            "fx.trie.dmin": i32(tf["dmin"]),
            "fx.trie.dmax": i32(tf["dmax"]),
            "fx.trie.nends": i32(tf["nends"]),
            "fx.trie.nf": f32(tf["nf"]),
            "fx.dec.state": i32(states),
            "fx.dec.z": f32(z),
            "fx.dec.logits": f32(logits),
            "fx.cand.offset": i32(cand_off),
            "fx.cand.token": i32(cand_tok),
            "fx.cand.dest": i32(cand_dest),
            "fx.cand.x": f32(x.numpy()),
            "fx.expected_bonus": f32(b32.numpy()),
            "fx.expected_argmax": i32(argmax),
        }
    )
    meta = model_metadata(variant, 1.0)
    meta.update(
        {
            "fixture": "parity",
            "seed": str(seed),
            "argmax_lambda": "1.0",
            "min_top2_gap": repr(gap),
            "tokens": str(BLANK),
            "note": "synthetic; model tensors are the keys without the fx. prefix",
        }
    )
    return tensors, meta


def write_parity(out_dir, variants=VARIANTS, seed=1234):
    out_dir = Path(out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)
    paths = []
    for v in variants:
        tensors, meta = parity_case(v, seed)
        p = out_dir / f"parity-{v}.safetensors"
        save_file(tensors, str(p), metadata=meta)
        paths.append(p)
    return paths


# ------------------------------------------------------------ prep shards


def synthetic_shard(path, seed=0, utterances=4, session="synthcall", split="train", sample=0,
                    phrases=None, joint=None, signal=True, dataset="spgispeech", identity=None,
                    samples=2, split_session_ids=None, policy_extra=None, meta_extra=None):
    """Write a synthetic shard in the CONTRACT-2 §4 layout, with metadata in
    the layout of R2's "Shard validation fields": `call` =
    "{dataset}/{session}", a bundled `policy` (production keys, synthetic
    values; `policy_extra` overrides policy keys) with `policy_sha256`, and
    each policy key repeated as a metadata field. `identity`: a
    provenance.ExportIdentity for the export fields. `meta_extra` overrides
    metadata fields after the policy is bundled (None removes one), to make
    inconsistent shards. With `signal`, every other decision is a correction
    labelled with a random candidate (usually not the base argmax), so a
    model can learn to boost it (a toy problem). Preservation labels are the
    base argmax when `joint` is given, random otherwise."""
    rng = np.random.default_rng(seed)
    if phrases is None:
        phrases = synthetic_phrases(rng, extra=6)
    bt = BiasTrie(phrases)
    tf = trie_arrays(bt)
    root, offsets, rows = bt.override_table()
    lens = rng.integers(3, 8, size=utterances)
    frames = rng.integers(10, 20, size=utterances)
    enc = rng.normal(0.0, 1.0, size=(int(frames.sum()), J)).astype(np.float32)
    pred = rng.normal(0.0, 1.0, size=(int((lens + 1).sum()), J)).astype(np.float32)
    foff = np.concatenate([[0], np.cumsum(frames)]).astype(np.int64)
    poff = np.concatenate([[0], np.cumsum(lens + 1)]).astype(np.int64)
    d_utt, d_t, d_u, d_state, d_label, d_kind = [], [], [], [], [], []
    for u in range(utterances):
        state = ROOT
        for k in range(int(lens[u]) + 1):
            t = int(rng.integers(0, frames[u]))
            cands = bt.candidates(state)
            corr = signal and k % 2 == 0
            if corr:
                label = cands[int(rng.integers(0, len(cands)))][0]
            elif joint is not None:
                z = torch.relu(torch.from_numpy(enc[foff[u] + t] + pred[poff[u] + k]))[None]
                label = int(joint.token_logits(z).argmax())
            else:
                label = int(rng.integers(0, V))
            d_utt.append(u)
            d_t.append(t)
            d_u.append(k)
            d_state.append(state)
            d_label.append(label)
            d_kind.append(1 if corr else 0)
            if label != BLANK:
                state = bt.step(state, label)
    i32 = lambda a: np.ascontiguousarray(np.asarray(a, dtype=np.int32))  # noqa: E731
    tensors = {
        "trie.token": i32(tf["token"]),
        "trie.depth": i32(tf["depth"]),
        "trie.parent": i32(tf["parent"]),
        "trie.nf": np.ascontiguousarray(tf["nf"]),
        "cand.root": i32(root).reshape(-1, 2),
        "cand.override.offset": np.asarray(offsets, dtype=np.int64),
        "cand.override": i32(rows).reshape(-1, 2),
        "g_size": np.asarray(g_size(entries_of(phrases)), dtype=np.float32),
        "utt.frame_offset": foff,
        "enc": enc,
        "utt.pred_offset": poff,
        "pred": pred,
        "dec.utt": i32(d_utt),
        "dec.t": i32(d_t),
        "dec.u": i32(d_u),
        "dec.state": i32(d_state),
        "dec.label": i32(d_label),
        "dec.kind": np.asarray(d_kind, dtype=np.uint8),
    }
    from .provenance import (RARE_RULE, SPLIT_RULE_OTHER, SPLIT_RULES, TRAIN_CASING, canonical, session_set_sha256,
                             sha256_hex)

    sessions = list(split_session_ids) if split_session_ids is not None else [session]

    policy = {
        "format": "lf-bias-prep-v1",
        "dataset": dataset,
        "split": split,
        "casing": TRAIN_CASING.get(dataset, "cased"),
        "targets_mode": "rare",
        "rare_rule": dict(RARE_RULE, common_words_file_sha256="c" * 64),
        "df_source": {"manifests": [{"path": f"/synthetic/{dataset}/train.jsonl", "sha256": "a" * 64}],
                      "split": "train", "sessions": 40, "max_df": 2},
        "df_source_sha256": "d" * 64,
        "split_rule": SPLIT_RULES.get(dataset, SPLIT_RULE_OTHER),
        "manifest_sha256": "b" * 64,
        "seed": str(SEED),
        "samples": samples,
        "export_sha256": identity.export_sha256 if identity else "synthetic",
        "cache_identity": identity.cache_identity if identity else "synthetic",
        "graph": {"case_variants": True, "cancel_unfinished": False},
        "split_sessions": len(sessions),
        "split_sessions_sha256": session_set_sha256(sessions),
    }
    policy.update(policy_extra or {})
    pol_s = canonical(policy)
    meta = {k: (v if isinstance(v, str) else canonical(v)) for k, v in policy.items()}
    meta.update({
        "call": f"{dataset}/{session}",
        "session": session,
        "sample": str(sample),
        "policy": pol_s,
        "policy_sha256": sha256_hex(pol_s.encode()),
        "entries": str(entries_of(phrases)),
        "phrases": str(len(phrases)),
        "nodes": str(bt.states()),
        "utterances": str(utterances),
        "decisions": str(len(d_label)),
        "corrections": str(sum(d_kind)),
        "synthetic": "1",
    })
    meta.update(meta_extra or {})
    meta = {k: v for k, v in meta.items() if v is not None}
    Path(path).parent.mkdir(parents=True, exist_ok=True)
    save_file(tensors, str(path), metadata=meta)
    return bt, phrases


INDEX_TEXT_FIELDS = ("dataset", "call", "session", "split", "policy_sha256", "df_source_sha256")
INDEX_NUM_FIELDS = ("sample", "utterances", "decisions", "corrections", "entries", "nodes")


def write_index(prep_dir):
    """`prep/index.json` rebuilt from every shard present, in the layout of
    R2's `rebuild_index` (format v2; numbers as floats, as Rust writes them;
    per (dataset, split) policy, expected/present shards and `complete`)."""
    from safetensors import safe_open

    prep_dir = Path(prep_dir)
    splits, groups = {}, {}
    for name in ("train", "dev"):
        d = prep_dir / name
        shards, totals = [], {"shards": 0.0, "decisions": 0.0}
        for p in sorted(d.glob("*.safetensors")) if d.is_dir() else []:
            with safe_open(str(p), framework="np") as f:
                m = f.metadata() or {}
            e = {"path": f"{name}/{p.name}"}
            e.update({k: m.get(k, "") for k in INDEX_TEXT_FIELDS})
            e.update({k: float(m.get(k, 0)) for k in INDEX_NUM_FIELDS})
            shards.append(e)
            totals["shards"] += 1
            totals["decisions"] += float(m.get("decisions", 0))
            g = groups.setdefault((m.get("dataset"), name), {
                "policy": json.loads(m["policy"]) if "policy" in m else None,
                "policy_sha256": m.get("policy_sha256", ""),
                "expected_shards": int(float(m.get("split_sessions", 0)) * float(m.get("samples", 0))),
                "present_shards": 0,
            })
            g["present_shards"] += 1
        splits[name] = {"shards": shards, "totals": totals}
    datasets = {}
    for (ds, name), g in sorted(groups.items()):
        g["complete"] = g["present_shards"] == g["expected_shards"]
        datasets.setdefault(ds, {"splits": {}})["splits"][name] = g
    index = {
        "format": "lf-bias-prep-index-v2",
        "shard_format": "lf-bias-prep-v1",
        "splits": splits,
        "datasets": datasets,
        "complete": bool(groups) and all(g["complete"] for g in groups.values()),
    }
    (prep_dir / "index.json").write_text(json.dumps(index, indent=2))
    return index


def synthetic_export(export_dir, seed=0):
    """A synthetic export directory: export.safetensors (joint output only,
    F16 like the real export) and a manifest.json naming its sha256."""
    from .provenance import sha256_file

    export_dir = Path(export_dir)
    export_dir.mkdir(parents=True, exist_ok=True)
    rng = np.random.default_rng(seed)
    w = rng.normal(0, 0.05, size=(V + DURATIONS, J)).astype(np.float16)
    b = rng.normal(0, 0.5, size=V + DURATIONS).astype(np.float16)
    weights = export_dir / "export.safetensors"
    save_file({"joint.joint_net.2.weight": w, "joint.joint_net.2.bias": b}, str(weights))
    digest = sha256_file(weights)
    man = {"format": "synthetic-export-v1", "file": "export.safetensors", "sha256": digest,
           "files": {"export.safetensors": digest}}
    (export_dir / "manifest.json").write_text(json.dumps(man, indent=2))
    return export_dir


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("parity", help="write parity-{L1,L2,L3,L3S}.safetensors")
    p.add_argument("--out", required=True, type=Path)
    p.add_argument("--seed", type=int, default=1234)
    a = ap.parse_args(argv)
    if a.cmd == "parity":
        for path in write_parity(a.out, seed=a.seed):
            print(path)
    return 0


if __name__ == "__main__":
    sys.exit(main())
