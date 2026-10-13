"""L1, L2, L3 and L3S (CONTRACT-2 §3). The modules' state_dict keys are
the contract's safetensors keys, so export is a direct dump."""

import math
from dataclasses import dataclass

import torch
import torch.nn.functional as F
from safetensors import safe_open
from safetensors.torch import save_file
from torch import nn

from . import BLANK, D, DEPTH_EMB, FF, FORMAT, HEADS, HID, J, LN_EPS, NF, NX, V

VARIANTS = ("L1", "L2", "L3", "L3S")
SUBTREE = ("L3", "L3S")  # variants with up.* and gate


def expected_shapes(variant):
    """Every tensor of a variant with its shape (the strict export key set)."""
    out = {}

    def lin(name, i, o):
        out[f"{name}.weight"] = (o, i)
        out[f"{name}.bias"] = (o,)

    def norm(name, d):
        out[f"{name}.weight"] = (d,)
        out[f"{name}.bias"] = (d,)

    if variant == "L1":
        lin("l1.0", NX, HID)
        lin("l1.1", HID, HID)
        lin("l1.2", HID, 1)
        return out
    if variant not in VARIANTS:
        raise ValueError(f"unknown variant {variant!r}")
    norm("q.ln", J)
    lin("q.1", J, D)
    lin("q.2", D, D)
    out["emb.tok"] = (V, D)
    out["emb.depth"] = (DEPTH_EMB, D)
    out["emb.end"] = (2, D)
    lin("node.in", NF, D)
    for k in range(2):
        lin(f"self.{k}.0", D, FF)
        lin(f"self.{k}.1", FF, D)
        norm(f"self.{k}.ln", D)
    lin("key", D, D)
    lin("sc.0", HEADS + NX, HID)
    lin("sc.1", HID, HID)
    lin("sc.2", HID, 1)
    if variant in SUBTREE:
        lin("up.0", 3 * D, FF)
        lin("up.1", FF, D)
        norm("up.ln", D)
        out["gate"] = (1,)
    return out


@dataclass
class Trie:
    """A dictionary's trie as tensors on one device (BiasGraph state order:
    root 0, parents before children), plus the levels the L3 pass needs."""

    token: torch.Tensor  # long [N], root = BLANK
    depth: torch.Tensor  # long [N]
    parent: torch.Tensor  # long [N], -1 for the root
    nf: torch.Tensor  # f32 [N, 5]
    # Deepest level first: node ids per depth, and for the children of each
    # level (the next deeper level) their parent's position in this level.
    levels: list
    child_pos: list

    @staticmethod
    def build(token, depth, parent, nf, device=None):
        token = torch.as_tensor(token, dtype=torch.long, device=device)
        depth = torch.as_tensor(depth, dtype=torch.long, device=device)
        parent = torch.as_tensor(parent, dtype=torch.long, device=device)
        nf = torch.as_tensor(nf, dtype=torch.float32, device=device)
        token = token.clone()
        token[0] = BLANK
        n = token.shape[0]
        maxd = int(depth.max().item()) if n else 0
        levels = [
            torch.nonzero(depth == d, as_tuple=False).flatten()
            for d in range(maxd, -1, -1)
        ]
        pos = torch.empty(n, dtype=torch.long, device=device)
        for lv in levels:
            pos[lv] = torch.arange(lv.shape[0], device=device)
        child_pos = [None]  # the deepest level has no children
        for i in range(1, len(levels)):
            child_pos.append(pos[parent[levels[i - 1]]])
        return Trie(token, depth, parent, nf, levels, child_pos)

    def to(self, device):
        return Trie(
            self.token.to(device),
            self.depth.to(device),
            self.parent.to(device),
            self.nf.to(device),
            [x.to(device) for x in self.levels],
            [None if x is None else x.to(device) for x in self.child_pos],
        )


def _lins(*dims):
    return nn.ModuleList(nn.Linear(a, b) for a, b in dims)


class BiasModel(nn.Module):
    """Raw scores -> b = 8·tanh(raw/8) per candidate.

    Usage per batch (one dictionary): `nodes = model.node_pass(trie)` once,
    then `model.bonus(nodes, z, x, cand_dec, cand_dest)`."""

    def __init__(self, variant):
        super().__init__()
        if variant not in VARIANTS:
            raise ValueError(f"unknown variant {variant!r}")
        self.variant = variant
        if variant == "L1":
            self.l1 = _lins((NX, HID), (HID, HID), (HID, 1))
        else:
            self.q = nn.ModuleDict(
                {"ln": nn.LayerNorm(J, eps=LN_EPS), "1": nn.Linear(J, D), "2": nn.Linear(D, D)}
            )
            # PyTorch's default for embeddings is N(0, 1), as nn.Embedding.
            self.emb = nn.ParameterDict(
                {
                    "tok": nn.Parameter(torch.randn(V, D)),
                    "depth": nn.Parameter(torch.randn(DEPTH_EMB, D)),
                    "end": nn.Parameter(torch.randn(2, D)),
                }
            )
            self.node = nn.ModuleDict({"in": nn.Linear(NF, D)})
            self.add_module(
                "self",
                nn.ModuleList(
                    nn.ModuleDict(
                        {
                            "0": nn.Linear(D, FF),
                            "1": nn.Linear(FF, D),
                            "ln": nn.LayerNorm(D, eps=LN_EPS),
                        }
                    )
                    for _ in range(2)
                ),
            )
            self.key = nn.Linear(D, D)
            self.sc = _lins((HEADS + NX, HID), (HID, HID), (HID, 1))
            if variant in SUBTREE:
                self.up = nn.ModuleDict(
                    {
                        "0": nn.Linear(3 * D, FF),
                        "1": nn.Linear(FF, D),
                        "ln": nn.LayerNorm(D, eps=LN_EPS),
                    }
                )
                self.gate = nn.Parameter(torch.zeros(1))
        final = self.l1[2] if variant == "L1" else self.sc[2]
        nn.init.zeros_(final.weight)
        nn.init.zeros_(final.bias)

    # ------------------------------------------------------------ node pass

    def node_pass(self, trie):
        """Keys k(n) [N, D] for L2/L3/L3S (None for L1). Run once per dictionary
        per batch."""
        if self.variant == "L1":
            return None
        e = (
            self.emb["tok"][trie.token]
            + self.emb["depth"][trie.depth.clamp(max=DEPTH_EMB - 1)]
            + self.emb["end"][(trie.nf[:, 1] > 0.5).long()]
            + self.node["in"](trie.nf)
        )
        h = e
        for layer in self._modules["self"]:
            h = layer["ln"](h + layer["1"](F.gelu(layer["0"](h))))
        s = h
        if self.variant == "L3S":
            t = self._update(s, torch.zeros_like(s), torch.zeros_like(s))
        elif self.variant == "L3":
            t = self._aggregate(trie, s)
        else:
            t = s
        return self.key(t)

    def _update(self, s, mx, mean):
        """t = s + gate·LN_up(up.1(gelu(up.0([s; c])))), c = [mx; mean] (the
        residual outside the norm, so gate 0 gives t = s exactly)."""
        u = self.up["1"](F.gelu(self.up["0"](torch.cat([s, mx, mean], dim=1))))
        return s + self.gate * self.up["ln"](u)

    def _aggregate(self, trie, s):
        """L3: t(n) = s(n) + gate·LN_up(up.1(gelu(up.0([s; max_c t; mean_c t])))),
        deepest level first; leaves pool zeros."""
        outs = []
        prev = None  # t of the previous (deeper) level
        for i, lv in enumerate(trie.levels):
            s_lv = s[lv]
            n = lv.shape[0]
            if prev is None:
                mx = torch.zeros_like(s_lv)
                mean = torch.zeros_like(s_lv)
            else:
                idx = trie.child_pos[i]
                ix = idx[:, None].expand(-1, s.shape[1])
                mx = torch.zeros_like(s_lv).scatter_reduce(
                    0, ix, prev, reduce="amax", include_self=False
                )
                total = torch.zeros_like(s_lv).index_add(0, idx, prev)
                cnt = torch.zeros(n, dtype=s.dtype, device=s.device).index_add(
                    0, idx, torch.ones_like(idx, dtype=s.dtype)
                )
                mean = total / cnt.clamp(min=1)[:, None]
            t_lv = self._update(s_lv, mx, mean)
            outs.append(t_lv)
            prev = t_lv
        order = torch.cat(trie.levels)
        inv = torch.empty_like(order)
        inv[order] = torch.arange(order.shape[0], device=order.device)
        return torch.cat(outs)[inv]

    # ------------------------------------------------------------ scoring

    def query(self, z):
        return self.q["2"](F.gelu(self.q["1"](self.q["ln"](z))))

    def raw(self, keys, z, x, cand_dec, cand_dest):
        """Raw score per candidate. z: [B, J] joint hidden; x: [K, 10]
        candidate features; cand_dec: [K] decision index into z; cand_dest:
        [K] destination node."""
        if self.variant == "L1":
            l = self.l1
            return l[2](F.gelu(l[1](F.gelu(l[0](x))))).squeeze(-1)
        q = self.query(z)
        dh = D // HEADS
        # a_h = q_h·k_h / 8 (dh = 64). Dense over the batch's distinct
        # destinations, then gathered: much less memory than gathering
        # [K, D] query and key rows when K = decisions × candidates is large.
        ud, inv = torch.unique(cand_dest, return_inverse=True)
        dots = torch.einsum(
            "bhd,nhd->bnh", q.view(-1, HEADS, dh), keys[ud].view(-1, HEADS, dh)
        )
        a = dots[cand_dec, inv] / math.sqrt(dh)
        h = torch.cat([a, x], dim=1)
        return self.sc[2](F.gelu(self.sc[1](F.gelu(self.sc[0](h))))).squeeze(-1)

    def bonus(self, keys, z, x, cand_dec, cand_dest):
        """b = 8·tanh(raw/8) per candidate (before λ)."""
        return 8.0 * torch.tanh(self.raw(keys, z, x, cand_dec, cand_dest) / 8.0)


def fused_logits(token_logits, cand_dec, cand_tok, b, lam=1.0):
    """ℓ + λ·b at the candidates (each (decision, token) pair is unique)."""
    return token_logits.index_put((cand_dec, cand_tok), lam * b, accumulate=True)


def param_count(model):
    return sum(p.numel() for p in model.parameters())


# ------------------------------------------------------------ files


def check_tensors(variant, tensors):
    """Strict key and shape check (as the Rust loader): raises on missing,
    extra or wrong-shaped tensors."""
    want = expected_shapes(variant)
    have = {k: tuple(v.shape) for k, v in tensors.items()}
    missing = sorted(set(want) - set(have))
    extra = sorted(set(have) - set(want))
    bad = sorted(k for k in set(want) & set(have) if want[k] != have[k])
    if missing or extra or bad:
        raise ValueError(
            f"{variant}: missing {missing}, extra {extra}, "
            f"wrong shape {[(k, have[k], want[k]) for k in bad]}"
        )


def export_tensors(model):
    t = {k: v.detach().to("cpu", torch.float32).contiguous() for k, v in model.state_dict().items()}
    check_tensors(model.variant, t)
    return t


def model_metadata(variant, lam):
    return {"variant": variant, "lambda": repr(float(lam)), "d": str(D), "format": FORMAT}


def export_model(model, path, lam=1.0):
    """Write the CONTRACT-2 §3 model file."""
    save_file(export_tensors(model), str(path), metadata=model_metadata(model.variant, lam))


def load_model(path, device="cpu"):
    """Load a model file strictly. Returns (model, lambda)."""
    with safe_open(str(path), framework="pt", device="cpu") as f:
        meta = f.metadata() or {}
        tensors = {k: f.get_tensor(k) for k in f.keys()}
    if meta.get("format") != FORMAT or meta.get("d") != str(D):
        raise ValueError(f"bad model metadata {meta}")
    variant = meta.get("variant")
    check_tensors(variant, tensors)
    for k, v in tensors.items():
        if v.dtype != torch.float32:
            raise ValueError(f"{k}: dtype {v.dtype}, expected float32")
    model = BiasModel(variant)
    model.load_state_dict(tensors, strict=True)
    return model.to(device), float(meta["lambda"])
