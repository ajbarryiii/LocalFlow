"""Node and candidate features, CONTRACT-2 §2 (identical to lf-bench
`learned.rs`: `TrieFeatures`, `g_size`, `logit_features`)."""

import math

import numpy as np
import torch

from . import BLANK, DMAX_CAP, V


def trie_features(token, parent, is_end):
    """Per-node features of a trie given in BiasGraph state order (root 0,
    every parent before its children).

    Returns a dict of numpy arrays: token (root = BLANK), depth, is_end, dmin,
    dmax (capped at DMAX_CAP), nends, parent, and nf (f32 [N, 5]) =
    [depth/8, is_end, dmin/8, dmax/8, ln(1+nends)/4]. A node with no phrase
    end in its subtree (only the root of an empty trie) has dmin = dmax = 0.
    """
    parent = np.asarray(parent, dtype=np.int64)
    n = len(parent)
    if n == 0 or parent[0] != -1:
        raise ValueError("trie needs a root with parent -1")
    token = np.array(token, dtype=np.int64)
    token[0] = BLANK
    is_end = np.asarray(is_end, dtype=bool)
    depth = np.zeros(n, dtype=np.int64)
    for i in range(1, n):
        p = parent[i]
        if not 0 <= p < i:
            raise ValueError(f"node {i} has parent {p}")
        if not 0 <= token[i] < BLANK:
            raise ValueError(f"node {i} has token {token[i]}")
        depth[i] = depth[p] + 1
    big = np.iinfo(np.int64).max
    dmin = np.full(n, big, dtype=np.int64)
    dmax = np.zeros(n, dtype=np.int64)
    nends = np.zeros(n, dtype=np.int64)
    anyend = np.zeros(n, dtype=bool)
    for i in range(n - 1, -1, -1):
        if is_end[i]:
            dmin[i] = 0
            nends[i] += 1
            anyend[i] = True
        if i > 0 and anyend[i]:
            p = parent[i]
            dmin[p] = min(dmin[p], dmin[i] + 1)
            dmax[p] = max(dmax[p], min(dmax[i] + 1, DMAX_CAP))
            nends[p] += nends[i]
            anyend[p] = True
    dmin[dmin == big] = 0
    nf = np.stack(
        [
            depth.astype(np.float32) / np.float32(8),
            is_end.astype(np.float32),
            dmin.astype(np.float32) / np.float32(8),
            dmax.astype(np.float32) / np.float32(8),
            np.log(np.float32(1) + nends.astype(np.float32)) / np.float32(4),
        ],
        axis=1,
    ).astype(np.float32)
    return {
        "token": token,
        "depth": depth,
        "is_end": is_end,
        "dmin": dmin,
        "dmax": dmax,
        "nends": nends,
        "parent": parent,
        "nf": nf,
    }


def g_size(entries):
    """ln(1 + entries) / 7, entries = deduplicated entries before case
    variants."""
    return np.float32(math.log(1.0 + entries) / 7.0)


def logit_features(token_logits, cand_dec, cand_tok):
    """lf per candidate, [K, 4]: [ℓ_y/10, (ℓ_y − max ℓ)/10, logsoftmax_y/10,
    logsoftmax_blank/10], over the 1025 token rows of each decision's logits.

    token_logits: [B, >=1025] (durations ignored); cand_dec, cand_tok: [K]
    long. Max and log-sum-exp are taken in f64, as Rust does; the result has
    token_logits' dtype. No gradient flows (base logits are frozen data)."""
    with torch.no_grad():
        l = token_logits[:, :V]
        l64 = l.double()
        mx = l64.max(dim=1).values
        lse = mx + torch.log(torch.exp(l64 - mx[:, None]).sum(dim=1))
        ly = l64[cand_dec, cand_tok]
        out = torch.stack(
            [
                ly / 10.0,
                (ly - mx[cand_dec]) / 10.0,
                (ly - lse[cand_dec]) / 10.0,
                ((l64[:, BLANK] - lse) / 10.0)[cand_dec],
            ],
            dim=1,
        )
        return out.to(token_logits.dtype)


def candidate_features(nf, token_logits, cand_dec, cand_tok, cand_dest, gsize):
    """x per candidate, [K, 10] = [nf(dest) (5), lf (4), g_size (1)]."""
    lf = logit_features(token_logits, cand_dec, cand_tok)
    g = torch.full(
        (cand_dec.shape[0], 1), float(gsize), dtype=lf.dtype, device=lf.device
    )
    return torch.cat([nf[cand_dest].to(lf.dtype), lf, g], dim=1)
