import math
import tempfile
import unittest
from pathlib import Path

import numpy as np
import torch
import torch.nn.functional as F
from safetensors import safe_open
from safetensors.torch import save_file

# Importable both as `tests.<module>` (-t) and as a top-level module (-s only).
_ROOT = str(__import__("pathlib").Path(__file__).resolve().parents[1])  # linux/tools/learned-bias
if _ROOT not in __import__("sys").path:
    __import__("sys").path.insert(0, _ROOT)

from learned_bias import D, FORMAT, J, V
from learned_bias.features import candidate_features
from learned_bias.fixtures import randomize, synthetic_phrases, trie_arrays
from learned_bias.model import (
    BiasModel,
    Trie,
    expected_shapes,
    export_model,
    export_tensors,
    fused_logits,
    load_model,
    param_count,
)
from learned_bias.trie import BiasTrie


def small_case(seed=0, decisions=6):
    rng = np.random.default_rng(seed)
    bt = BiasTrie(synthetic_phrases(rng, extra=4))
    tf = trie_arrays(bt)
    trie = Trie.build(tf["token"], tf["depth"], tf["parent"], tf["nf"])
    states = [0, 1, 2, 3, 0, int(np.argmax(tf["depth"])) - 1][:decisions]
    dec, tok, dest = [], [], []
    for i, s in enumerate(states):
        for t, d in bt.candidates(s):
            dec.append(i)
            tok.append(t)
            dest.append(d)
    z = torch.relu(torch.from_numpy(rng.normal(0, 1, size=(len(states), J)).astype(np.float32)))
    l = torch.from_numpy(rng.normal(0, 3, size=(len(states), V)).astype(np.float32))
    cd, ct, cdst = torch.tensor(dec), torch.tensor(tok), torch.tensor(dest)
    x = candidate_features(trie.nf, l, cd, ct, cdst, 0.5)
    return bt, tf, trie, z, l, x, cd, ct, cdst


def bonus(model, case):
    _, _, trie, z, _, x, cd, _, cdst = case
    with torch.no_grad():
        return model.bonus(model.node_pass(trie), z, x, cd, cdst)


class ShapeAndExportTests(unittest.TestCase):
    def test_exact_parameter_counts(self):
        counts = {v: param_count(BiasModel(v)) for v in ("L1", "L2", "L3", "L3S")}
        self.assertEqual(counts, {"L1": 4929, "L2": 3_499_585, "L3": 5_599_298, "L3S": 5_599_298})
        m = BiasModel("L3")
        sub = sum(p.numel() for n, p in m.named_parameters() if n.startswith("up.") or n == "gate")
        self.assertEqual(sub, 2_099_713)

    def test_state_dict_is_the_contract_key_set(self):
        for v in ("L1", "L2", "L3", "L3S"):
            sd = BiasModel(v).state_dict()
            self.assertEqual({k: tuple(t.shape) for k, t in sd.items()}, expected_shapes(v))
        self.assertEqual(expected_shapes("L3"), expected_shapes("L3S"))
        l2 = set(expected_shapes("L2"))
        extra = set(expected_shapes("L3")) - l2
        self.assertEqual(
            extra,
            {"up.0.weight", "up.0.bias", "up.1.weight", "up.1.bias", "up.ln.weight", "up.ln.bias", "gate"},
        )
        for k in ("emb.tok", "emb.depth", "emb.end", "q.ln.weight", "self.1.ln.bias", "node.in.weight", "sc.2.bias"):
            self.assertIn(k, l2)

    def test_export_round_trip_and_metadata(self):
        torch.manual_seed(1)
        with tempfile.TemporaryDirectory() as d:
            for v in ("L1", "L2", "L3", "L3S"):
                m = BiasModel(v)
                randomize(m, torch.Generator().manual_seed(2))
                p = Path(d) / f"{v}.safetensors"
                export_model(m, p, lam=0.71)
                with safe_open(str(p), framework="pt") as f:
                    meta = f.metadata()
                    self.assertEqual(set(f.keys()), set(expected_shapes(v)))
                    self.assertTrue(all(f.get_tensor(k).dtype == torch.float32 for k in f.keys()))
                self.assertEqual(meta, {"variant": v, "lambda": "0.71", "d": str(D), "format": FORMAT})
                m2, lam = load_model(p)
                self.assertEqual((m2.variant, lam), (v, 0.71))
                for k, t in m.state_dict().items():
                    torch.testing.assert_close(m2.state_dict()[k], t, rtol=0, atol=0)

    def test_loader_rejects_missing_extra_and_misshaped(self):
        with tempfile.TemporaryDirectory() as d:
            t = export_tensors(BiasModel("L2"))
            meta = {"variant": "L2", "lambda": "1.0", "d": "512", "format": FORMAT}
            bad = []
            bad.append({k: v for k, v in t.items() if k != "key.bias"})
            bad.append(dict(t, extra=torch.zeros(1)))
            bad.append(dict(t, **{"emb.depth": torch.zeros(15, D)}))
            for i, tensors in enumerate(bad):
                p = Path(d) / f"bad{i}.safetensors"
                save_file(tensors, str(p), metadata=meta)
                with self.assertRaises(ValueError):
                    load_model(p)
            # An L3 file labelled L2 is rejected (extra tensors).
            p = Path(d) / "l3.safetensors"
            save_file(export_tensors(BiasModel("L3")), str(p), metadata=meta)
            with self.assertRaises(ValueError):
                load_model(p)


class InitTests(unittest.TestCase):
    def test_bonus_is_zero_at_init(self):
        case = small_case()
        for v in ("L1", "L2", "L3", "L3S"):
            torch.manual_seed(5)
            m = BiasModel(v)
            self.assertTrue(torch.all(m.sc[2].weight == 0) if v != "L1" else torch.all(m.l1[2].weight == 0))
            b = bonus(m, case)
            self.assertTrue(torch.all(b == 0), v)
            if v in ("L3", "L3S"):
                self.assertEqual(m.gate.item(), 0.0)

    def test_gate_zero_l3_and_l3s_equal_l2_exactly(self):
        case = small_case()
        torch.manual_seed(7)
        l2 = BiasModel("L2")
        randomize(l2, torch.Generator().manual_seed(8))  # b != 0
        b2 = bonus(l2, case)
        self.assertGreater(float(b2.abs().max()), 0.1)
        for v in ("L3", "L3S"):
            torch.manual_seed(9)
            m = BiasModel(v)
            m.load_state_dict(l2.state_dict(), strict=False)
            # Random subtree layers, gate left at its initial 0.
            self.assertEqual(m.gate.item(), 0.0)
            torch.testing.assert_close(bonus(m, case), b2, rtol=0, atol=0)
            # A non-zero gate changes it.
            with torch.no_grad():
                m.gate.fill_(1.0)
            self.assertGreater(float((bonus(m, case) - b2).abs().max()), 1e-4)


def reference_bonus(m, tf, z, x, cd, cdst):
    """Direct per-node, per-candidate transcription of CONTRACT-2 §3 (f64)."""
    P = {k: v.double() for k, v in m.state_dict().items()}
    lin = lambda name, h: h @ P[f"{name}.weight"].T + P[f"{name}.bias"]  # noqa: E731

    def ln(name, h):
        mu = h.mean(-1, keepdim=True)
        var = ((h - mu) ** 2).mean(-1, keepdim=True)
        return (h - mu) / torch.sqrt(var + 1e-5) * P[f"{name}.weight"] + P[f"{name}.bias"]

    g = lambda h: F.gelu(h)  # noqa: E731
    x = x.double()
    if m.variant == "L1":
        raw = lin("l1.2", g(lin("l1.1", g(lin("l1.0", x))))).squeeze(-1)
        return 8 * torch.tanh(raw / 8)
    n = len(tf["token"])
    nf = torch.from_numpy(tf["nf"]).double()
    s = {}
    for i in range(n):
        h = (P["emb.tok"][tf["token"][i]] + P["emb.depth"][min(tf["depth"][i], 15)]
             + P["emb.end"][int(tf["is_end"][i])] + lin("node.in", nf[i]))
        for k in range(2):
            h = ln(f"self.{k}.ln", h + lin(f"self.{k}.1", g(lin(f"self.{k}.0", h))))
        s[i] = h
    children = {i: [c for c in range(n) if tf["parent"][c] == i] for i in range(n)}
    t = {}

    def tnode(i):
        if i in t:
            return t[i]
        if m.variant == "L2":
            t[i] = s[i]
            return t[i]
        kids = [tnode(c) for c in children[i]] if m.variant == "L3" else []
        if kids:
            st = torch.stack(kids)
            c = torch.cat([st.max(0).values, st.mean(0)])
        else:
            c = torch.zeros(2 * D, dtype=torch.float64)
        u = lin("up.1", g(lin("up.0", torch.cat([s[i], c]))))
        t[i] = s[i] + P["gate"][0] * ln("up.ln", u)
        return t[i]

    q = lin("q.2", g(lin("q.1", ln("q.ln", z.double()))))
    out = []
    for k in range(len(cd)):
        key = lin("key", tnode(int(cdst[k])))
        qq = q[int(cd[k])]
        a = torch.stack([qq[h * 64:(h + 1) * 64] @ key[h * 64:(h + 1) * 64] / 8 for h in range(8)])
        raw = lin("sc.2", g(lin("sc.1", g(lin("sc.0", torch.cat([a, x[k]]))))))
        out.append(8 * torch.tanh(raw[0] / 8))
    return torch.stack(out)


class ForwardTests(unittest.TestCase):
    def test_matches_direct_transcription_of_the_contract(self):
        case = small_case(seed=11)
        _, tf, trie, z, _, x, cd, _, cdst = case
        for v in ("L1", "L2", "L3", "L3S"):
            torch.manual_seed(12)
            m = BiasModel(v)
            randomize(m, torch.Generator().manual_seed(13))
            got = bonus(m, case).double()
            want = reference_bonus(m, tf, z, x, cd, cdst)
            self.assertGreater(float(want.abs().max()), 0.5)
            torch.testing.assert_close(got, want, rtol=1e-4, atol=1e-4, msg=v)

    def test_l3_differs_from_l3s_only_through_children(self):
        case = small_case(seed=11)
        torch.manual_seed(14)
        l3 = BiasModel("L3")
        randomize(l3, torch.Generator().manual_seed(15))
        l3s = BiasModel("L3S")
        l3s.load_state_dict(l3.state_dict())
        _, _, trie, *_ = case
        with torch.no_grad():
            k3, ks = l3.node_pass(trie), l3s.node_pass(trie)
        leaves = torch.tensor([i for i in range(len(trie.token)) if not bool((trie.parent == i).any())])
        inner = torch.tensor([i for i in range(1, len(trie.token)) if bool((trie.parent == i).any())])
        # Equal up to f32 summation order (L3 batches per level, L3S at once).
        torch.testing.assert_close(k3[leaves], ks[leaves], rtol=1e-5, atol=1e-5)
        self.assertGreater(float((k3[inner] - ks[inner]).abs().max()), 1e-3)

    def test_bonus_bounded_and_fused(self):
        case = small_case()
        _, _, trie, z, l, x, cd, ct, cdst = case
        m = BiasModel("L1")
        with torch.no_grad():
            m.l1[2].bias.fill_(100.0)
        b = bonus(m, case)
        self.assertTrue(torch.all(b <= 8.0) and torch.all(b > 7.99))
        f = fused_logits(l, cd, ct, b, 0.5)
        torch.testing.assert_close(f[cd, ct], l[cd, ct] + 0.5 * b)
        mask = torch.ones_like(l, dtype=torch.bool)
        mask[cd, ct] = False
        torch.testing.assert_close(f[mask], l[mask], rtol=0, atol=0)


if __name__ == "__main__":
    unittest.main()
