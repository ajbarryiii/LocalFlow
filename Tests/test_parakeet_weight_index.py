import hashlib
import importlib.util
import json
from pathlib import Path
import struct
import tempfile
import unittest

spec = importlib.util.spec_from_file_location("weight_index", Path(__file__).resolve().parents[1] / "scripts/parakeet_weight_index.py")
index = importlib.util.module_from_spec(spec)
spec.loader.exec_module(index)
try:
    import numpy as np
except ImportError:
    np = None


class WeightStorageTests(unittest.TestCase):
    def blob(self):
        data = bytearray(192)
        struct.pack_into("<IIQQQ", data, 64, 0xDEADBEEF, 9, 2, 128, 7)
        data[128:130] = b"\x55\x01"
        return data

    def test_bounds_dtype_and_padding(self):
        self.assertEqual(bytes(index.checked_blob(self.blob(), 64, "uint1", (9,))), b"\x55\x01")
        for field, value, fmt in ((64, 0, "I"), (68, 11, "I"), (72, 1, "Q"),
                                  (80, 64, "Q"), (80, 192, "Q"), (88, 0, "Q")):
            data = self.blob()
            struct.pack_into("<" + fmt, data, field, value)
            with self.assertRaises(ValueError):
                index.checked_blob(data, 64, "uint1", (9,))
        for offset in (0, 65, 192):
            with self.assertRaises(ValueError):
                index.checked_blob(self.blob(), offset, "uint1", (9,))

    def test_shape_and_last_operation_argument(self):
        self.assertEqual(index.shape("8, 64, 1"), (8, 64, 1))
        for dimensions in ("0, 64", "-1, 2", "1024, 1000000"):
            with self.assertRaises(ValueError):
                index.shape(dimensions)
        self.assertEqual(dict(index.ARG.findall("perm = axes, x = added_bias")), {"perm": "axes", "x": "added_bias"})

    def test_bundle_hash_and_path_validation(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            names = ("frontend.json", "frontend.f32bin", "decoder_joint.json", "decoder_joint.f32bin",
                     "vocabulary.json", "Encoder.mlmodelc/model.mil", "Encoder.mlmodelc/weights/weight.bin")
            files = {}
            for name in names:
                path = directory / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(b"invented test bytes")
                files[name] = hashlib.sha256(path.read_bytes()).hexdigest()
            manifest = {"export_sha256": "a287e97719c451b785be2cd01ecc861fcaa010ebaa4ff2841783ec78fcd61503",
                        "encoder": "C6s8", "layout": "plain", "files": files}
            def write():
                (directory / "bundle.json").write_text(json.dumps(manifest))
            write()
            self.assertEqual(index.verify_bundle(directory), manifest)
            for unsafe in ("../escape", "/absolute"):
                files[unsafe] = "invented"
                write()
                with self.assertRaises(ValueError):
                    index.verify_bundle(directory)
                del files[unsafe]
            del files["frontend.json"]
            write()
            with self.assertRaises(ValueError):
                index.verify_bundle(directory)
            files["frontend.json"] = "0" * 64
            write()
            with self.assertRaises(ValueError):
                index.verify_bundle(directory)


@unittest.skipIf(np is None, "NumPy packing checks run in the pinned benchmark environment")
class TernaryPackingTests(unittest.TestCase):
    def test_blob_bit_and_nibble_order(self):
        reader = object.__new__(index.WeightIndex)
        reader.data = bytearray(192)
        struct.pack_into("<IIQQQ", reader.data, 64, 0xDEADBEEF, 11, 2, 128, 4)
        reader.data[128:130] = b"\xf0\x09"
        np.testing.assert_array_equal(reader.array(("uint4", (3,), 64)), [0, 15, 9])
        struct.pack_into("<IIQQQ", reader.data, 64, 0xDEADBEEF, 9, 2, 128, 7)
        reader.data[128:130] = b"\x55\x01"
        np.testing.assert_array_equal(reader.array(("uint1", (9,), 64)), [1, 0, 1, 0, 1, 0, 1, 0, 1])

    def fixture(self):
        codes = np.arange(512, dtype=np.uint32).reshape(8, 64) % 3
        mask = codes != 1
        positions = np.flatnonzero(mask)
        indices = ((positions // 64) % 8 * 2 + (codes.reshape(-1)[positions] == 0)).astype(np.uint8)
        scales = np.arange(1, 9, dtype=np.float16) / 16
        lut = np.stack((scales, -scales), axis=1).reshape(1, 16)
        reader = object.__new__(index.WeightIndex)
        reader.sparse = {"invented": ((8, 64), {"indices_mask": "mask", "indices_nonzero_data": "indices", "lut": "lut"})}
        arrays = {"mask": mask, "indices": indices, "lut": lut}
        reader.array = arrays.__getitem__
        return reader, arrays, codes, scales

    def test_reconstructs_zero_sign_and_per_row_scale(self):
        reader, _, codes, scales = self.fixture()
        packed, groups, affine_bias = reader.ternary("invented")
        unpacked = ((packed[:, :, None] >> (2 * np.arange(16, dtype=np.uint32))) & 3).reshape(8, 64)
        np.testing.assert_array_equal(unpacked, codes)
        np.testing.assert_array_equal(groups[:, 0], scales)
        np.testing.assert_array_equal(affine_bias, -groups)

    def test_wrong_row_scale_and_nonfinite_lut_rejected(self):
        reader, arrays, _, _ = self.fixture()
        arrays["indices"][0] ^= 2
        with self.assertRaises(ValueError):
            reader.ternary("invented")
        reader, arrays, _, _ = self.fixture()
        arrays["lut"][0, 0] = np.nan
        with self.assertRaises(ValueError):
            reader.ternary("invented")


if __name__ == "__main__":
    unittest.main()
