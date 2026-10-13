"""Reader for the training shards of CONTRACT-2 §4, written by Rust
`lf-bias-prep`: `W/prep/{split}/{call}.{sample}.safetensors`."""

import json
from pathlib import Path

import numpy as np
import torch
from safetensors import safe_open

from .features import g_size
from .model import Trie

TRIE_KEYS = ("trie.token", "trie.depth", "trie.parent", "trie.nf")
CAND_KEYS = ("cand.root", "cand.override.offset", "cand.override")
UTT_KEYS = ("utt.frame_offset", "enc", "utt.pred_offset", "pred")
DEC_KEYS = ("dec.utt", "dec.t", "dec.u", "dec.state", "dec.label", "dec.kind")
REQUIRED = TRIE_KEYS + CAND_KEYS + UTT_KEYS + DEC_KEYS + ("g_size",)


class Candidates:
    """Exact `BiasGraph::candidates(s)` from the root set and the per-state
    overrides: the root rows, with rows replaced (same token) or added by s's
    overrides, sorted by token."""

    def __init__(self, root, offset, rows):
        self.root = np.asarray(root, dtype=np.int64).reshape(-1, 2)
        self.offset = np.asarray(offset, dtype=np.int64)
        self.rows = np.asarray(rows, dtype=np.int64).reshape(-1, 2)
        if self.offset[0] != 0 or self.offset[-1] != len(self.rows):
            raise ValueError("cand.override.offset does not span cand.override")
        if np.any(np.diff(self.offset) < 0):
            raise ValueError("cand.override.offset is not monotone")
        self._root_map = {int(t): int(d) for t, d in self.root}
        if len(self._root_map) != len(self.root):
            raise ValueError("cand.root has duplicate tokens")
        self._cache = {}

    def states(self):
        return len(self.offset) - 1

    def get(self, state):
        """(tokens, dests), int64 arrays sorted by token."""
        hit = self._cache.get(state)
        if hit is not None:
            return hit
        a, b = self.offset[state], self.offset[state + 1]
        if a == b:
            out = (self.root[:, 0].copy(), self.root[:, 1].copy())
        else:
            m = dict(self._root_map)
            for t, d in self.rows[a:b]:
                m[int(t)] = int(d)
            toks = np.fromiter(sorted(m), dtype=np.int64, count=len(m))
            out = (toks, np.fromiter((m[t] for t in toks), dtype=np.int64, count=len(m)))
        self._cache[state] = out
        return out

    def list(self, state):
        t, d = self.get(state)
        return list(zip(t.tolist(), d.tolist()))


class Shard:
    """One dictionary sample of one call. Header and metadata are read on
    construction; tensors on `load`."""

    def __init__(self, path):
        self.path = Path(path)
        with safe_open(str(self.path), framework="np") as f:
            self.meta = dict(f.metadata() or {})
            keys = set(f.keys())
            missing = [k for k in REQUIRED if k not in keys]
            if missing:
                raise ValueError(f"{self.path}: missing tensors {missing}")
            self.decisions = int(f.get_slice("dec.label").get_shape()[0])
            self.nodes = int(f.get_slice("trie.token").get_shape()[0])
            enc = f.get_slice("enc").get_shape()
            self.joint_dim = int(enc[1]) if len(enc) == 2 else None
        # Identity comes from the metadata, never the file name (review B11).
        self.dataset = self.meta.get("dataset")
        self.call = self.meta.get("call")
        s = self.meta.get("sample")
        self.sample = int(s) if s is not None and str(s).lstrip("-").isdigit() else None

    @property
    def call_id(self):
        """Namespaced session id `dataset/session` (as R2 writes it, or built
        from the two fields); learning-curve subsets are nested by its hash."""
        if self.call is None:
            return None
        if "/" in self.call or self.dataset is None:
            return self.call
        return f"{self.dataset}/{self.call}"

    def arrays(self):
        """Every tensor as a numpy array."""
        with safe_open(str(self.path), framework="np") as f:
            return {k: f.get_tensor(k) for k in f.keys()}

    def load(self, device="cpu"):
        return ShardData(self, self.arrays(), device)


class ShardData:
    """A loaded shard on `device`."""

    def __init__(self, shard, a, device):
        self.shard = shard
        self.device = device
        n = len(a["trie.token"])
        self.trie = Trie.build(a["trie.token"], a["trie.depth"], a["trie.parent"], a["trie.nf"], device)
        # g_size comes from the shard, never recomputed: `entries` (distinct
        # encodable entry strings before case variants) is Rust's count.
        self.g_size = float(np.asarray(a["g_size"]).reshape(-1)[0])
        if "entries" in shard.meta:
            want = float(g_size(int(shard.meta["entries"])))
            if abs(want - self.g_size) > 1e-6:
                raise ValueError(f"{shard.path}: g_size {self.g_size} != ln(1+entries)/7 = {want}")
        self.cands = Candidates(a["cand.root"], a["cand.override.offset"], a["cand.override"])
        if self.cands.states() != n:
            raise ValueError(f"{shard.path}: {self.cands.states()} override states, {n} nodes")
        t = lambda k, dt: torch.as_tensor(np.ascontiguousarray(a[k])).to(device=device, dtype=dt)  # noqa: E731
        self.frame_offset = t("utt.frame_offset", torch.long)
        self.pred_offset = t("utt.pred_offset", torch.long)
        self.enc = t("enc", torch.float32)
        self.pred = t("pred", torch.float32)
        self.dec_utt = t("dec.utt", torch.long)
        self.dec_t = t("dec.t", torch.long)
        self.dec_u = t("dec.u", torch.long)
        self.dec_state = t("dec.state", torch.long)
        self.dec_label = t("dec.label", torch.long)
        self.dec_kind = t("dec.kind", torch.long)
        self.dec_state_np = np.asarray(a["dec.state"], dtype=np.int64)
        self._cand_dev = {}

    def decisions(self):
        return self.dec_label.shape[0]

    def z(self, idx):
        """Joint hidden relu(f_t + g_u) for decisions `idx` (long tensor)."""
        u = self.dec_utt[idx]
        f = self.enc[self.frame_offset[u] + self.dec_t[idx]]
        g = self.pred[self.pred_offset[u] + self.dec_u[idx]]
        return torch.relu(f + g)

    def _state_cands(self, s):
        hit = self._cand_dev.get(s)
        if hit is None:
            tok, dest = self.cands.get(s)
            hit = (
                torch.as_tensor(tok, device=self.device),
                torch.as_tensor(dest, device=self.device),
            )
            self._cand_dev[s] = hit
        return hit

    def batch_candidates(self, idx_np):
        """Flat candidates of decisions `idx_np` (numpy, positions in this
        shard): (cand_dec [K] index into the batch, cand_tok [K], cand_dest
        [K]), each decision's candidates sorted by token."""
        states = self.dec_state_np[idx_np]
        decs, toks, dests = [], [], []
        for s in np.unique(states):
            pos = torch.as_tensor(np.nonzero(states == s)[0], device=self.device)
            tok, dest = self._state_cands(int(s))
            decs.append(pos.repeat_interleave(tok.shape[0]))
            toks.append(tok.repeat(pos.shape[0]))
            dests.append(dest.repeat(pos.shape[0]))
        return torch.cat(decs), torch.cat(toks), torch.cat(dests)


def list_shards(prep_dir, split):
    """Shard paths of a split, from `index.json` if it lists them, else by
    globbing `prep_dir/split/*.safetensors`. Sorted by name."""
    prep_dir = Path(prep_dir)
    index = prep_dir / "index.json"
    paths = None
    if index.exists():
        data = json.loads(index.read_text())
        entry = data.get(split) if isinstance(data.get(split), (list, dict)) else None
        if entry is None and isinstance(data.get("splits"), dict):
            entry = data["splits"].get(split)
        if isinstance(entry, dict):
            entry = entry.get("shards")
        if isinstance(entry, list):
            paths = []
            for e in entry:
                p = e.get("path") if isinstance(e, dict) else e
                p = Path(p)
                paths.append(p if p.is_absolute() else prep_dir / p)
    if paths is None:
        paths = (prep_dir / split).glob("*.safetensors")
    return sorted(paths, key=lambda p: Path(p).name)
