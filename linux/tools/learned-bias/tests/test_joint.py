import struct
import unittest
from pathlib import Path

import numpy as np
import torch

# Importable both as `tests.<module>` (-t) and as a top-level module (-s only).
_ROOT = str(__import__("pathlib").Path(__file__).resolve().parents[1])  # linux/tools/learned-bias
if _ROOT not in __import__("sys").path:
    __import__("sys").path.insert(0, _ROOT)

from learned_bias import J, V
from learned_bias.joint import JointOutput, f16_round
from learned_bias.shards import Shard
from tests.helpers import prep_fixtures, real_export


def f16_bits_reference(x):
    """IEEE binary16 bits by round-to-nearest-even, via Python's struct 'e'."""
    return struct.unpack("<H", struct.pack("<e", float(x)))[0]


class F16RoundingTests(unittest.TestCase):
    def test_rounds_to_nearest_even_like_storage_f16(self):
        rng = np.random.default_rng(0)
        vals = np.concatenate([
            rng.normal(0, 1, 2000), rng.normal(0, 1e-5, 200),  # incl. subnormals
            [1 + 2**-11, 1 + 3 * 2**-11, -(1 + 2**-11), 65504.0, 2**-25, 2**-24, 0.0, -0.0],
        ]).astype(np.float32)
        got = f16_round(torch.from_numpy(vals)).numpy()
        want = np.array([np.float32(struct.unpack("<e", struct.pack("<H", f16_bits_reference(v)))[0])
                         for v in vals])
        np.testing.assert_array_equal(got, want)
        # Ties go to even: 1 + 2^-11 -> 1, 1 + 3·2^-11 -> 1 + 2^-9.
        self.assertEqual(float(got[-8]), 1.0)
        self.assertEqual(float(got[-7]), 1 + 2**-9)

    def test_token_logits(self):
        rng = np.random.default_rng(1)
        w = rng.normal(0, 0.05, size=(V + 5, J)).astype(np.float32)
        b = rng.normal(0, 1, size=V + 5).astype(np.float32)
        jo = JointOutput(torch.from_numpy(w), torch.from_numpy(b))
        z = torch.relu(torch.from_numpy(rng.normal(0, 1, size=(3, J)).astype(np.float32)))
        wr = w.astype(np.float16).astype(np.float64)
        want = z.numpy().astype(np.float64) @ wr.T + b.astype(np.float64)
        np.testing.assert_allclose(jo.rows(z).numpy(), want, rtol=1e-5, atol=1e-4)
        np.testing.assert_allclose(jo.token_logits(z).numpy(), jo.rows(z).numpy()[:, :V], rtol=1e-6, atol=1e-6)
        # The bias is not rounded to f16.
        np.testing.assert_array_equal(jo.bias.numpy(), b)


class ExportTests(unittest.TestCase):
    def test_export_joint_names_and_shapes(self):
        if not real_export():
            self.skipTest("set LF_EXPORT to check the real export")
        jo = JointOutput.from_export(real_export())
        self.assertEqual(tuple(jo.weight.shape), (V + 5, J))
        self.assertEqual(tuple(jo.bias.shape), (V + 5,))


class RustLogitDeviationTests(unittest.TestCase):
    """CONTRACT-2 §4: the Python base logits deviate from the Rust ones in a
    prep fixture by at most 1e-3. Needs a fixture with the Rust logits of its
    decisions (tensor `dec.logits`, [n, >=1025]); the joint weights come from
    the fixture (`joint.joint_net.2.weight`/`.bias`) if present, else the
    export."""

    def test_max_deviation_from_rust_logits(self):
        paths = prep_fixtures()
        tested = 0
        for p in paths:
            a = Shard(p).arrays()
            key = next((k for k in ("dec.logits", "logits", "rust.logits") if k in a), None)
            if key is None:
                continue
            if "joint.joint_net.2.weight" in a:
                jo = JointOutput(torch.from_numpy(a["joint.joint_net.2.weight"]),
                                 torch.from_numpy(a["joint.joint_net.2.bias"]))
            elif real_export():
                jo = JointOutput.from_export(real_export())
            else:
                continue
            sd = Shard(p).load()
            n = sd.decisions()
            rust = torch.from_numpy(np.asarray(a[key], dtype=np.float32))
            py = jo.rows(sd.z(torch.arange(n)))[:, : rust.shape[1]]
            dev = float((py - rust).abs().max())
            print(f"\n{Path(p).name}: max |Δℓ| = {dev:.3g} over {n} decisions")
            self.assertLessEqual(dev, 1e-3)
            tested += 1
        if not tested:
            self.skipTest("no Rust prep fixture with logits yet (set LF_PREP_FIXTURE)")


if __name__ == "__main__":
    unittest.main()
