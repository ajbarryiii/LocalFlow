"""Strict, benchmark-only reader for the pinned C6s8 MIL/blob layout.

This is not an Apple-supported runtime API. No tensors are saved or printed.
The caller verifies the bundle's hashes before constructing this reader.
"""
import math
from pathlib import Path
import re
import struct

TENSOR = r"tensor<(\w+), \[([\d, ]+)\]>"
BLOB = r'BLOBFILE\(path = string\("@model_path/weights/weight.bin"\), offset = uint64\((\d+)\)\)'
CONST = re.compile(TENSOR + r" (\w+) = const\(\)\[.*?val = " + TENSOR + r"\(" + BLOB + r"\)")
ARG = re.compile(r"(\w+) = (\w+)(?:,|\)|$)")
SPARSE = re.compile(TENSOR + r" (\w+)_sparse_0, " + TENSOR + r" \w+ = constexpr_lut_to_sparse\((.*?)\)\[name", re.S)
SPARSE_ARG = re.compile(r"(indices_mask|indices_nonzero_data|lut) = " + TENSOR + r"\(" + BLOB + r"\)")
OP = re.compile(TENSOR + r" (\w+) = (\w+)\((.*?)\)\[name")
BITS = {"fp16": 16, "fp32": 32, "uint1": 1, "uint4": 4, "int32": 32}
DTYPES = {"fp16": 1, "fp32": 2, "uint1": 9, "uint4": 11, "int32": 14}


def shape(text):
    result = tuple(int(x.strip()) for x in text.split(","))
    if not result or any(x <= 0 for x in result) or math.prod(result) > 32_000_000:
        raise ValueError("Unsupported tensor shape")
    return result


def checked_blob(data, offset, dtype, dimensions):
    """Check both the MIL declaration and the independent blob header bounds."""
    if dtype not in BITS or offset < 64 or offset % 64 or offset + 64 > len(data):
        raise ValueError("Invalid tensor header")
    sentinel, kind, size, start, padding = struct.unpack_from("<IIQQQ", data, offset)
    count = math.prod(dimensions)
    expected = (count * BITS[dtype] + 7) // 8
    if (sentinel != 0xDEADBEEF or kind != DTYPES[dtype] or size != expected
            or start < offset + 64 or start % 64 or start + size > len(data)
            or padding != expected * 8 - count * BITS[dtype]):
        raise ValueError("Invalid tensor storage")
    return memoryview(data)[start:start + size]


class WeightIndex:
    def __init__(self, directory):
        import mmap

        directory = Path(directory)
        text = (directory / "model.mil").read_text()
        # Parse only the default b15 function; constants can be deduplicated
        # across roles, so follow operation bindings rather than guessing names.
        functions = re.findall(r"func (\w+)\b", text)
        if not functions or functions[0] != "b15":
            raise ValueError("Unsupported default function")
        text = re.split(r"\bfunc b2\b", text, maxsplit=1)[0]
        self.file = (directory / "weights/weight.bin").open("rb")
        self.data = mmap.mmap(self.file.fileno(), 0, access=mmap.ACCESS_READ)
        if len(self.data) < 64 or struct.unpack_from("<II", self.data)[1] != 2:
            raise ValueError("Unsupported blob format")
        self.constants = {}
        for match in CONST.finditer(text):
            dtype, dims, name, value_dtype, value_dims, offset = match.groups()
            if dtype != value_dtype or shape(dims) != shape(value_dims) or name in self.constants:
                raise ValueError("Invalid constant declaration")
            self.constants[name] = (dtype, shape(dims), int(offset))
        self.sparse = {}
        for match in SPARSE.finditer(text):
            dtype, dims, name, output_dtype, nonzeros, args = match.groups()
            tensors = {key: (dt, shape(sh), int(off)) for key, dt, sh, off in SPARSE_ARG.findall(args)}
            if (dtype != "uint1" or output_dtype != "fp16" or name in self.sparse
                    or set(tensors) != {"indices_mask", "indices_nonzero_data", "lut"}
                    or tensors["indices_mask"][:2] != ("uint1", shape(dims))
                    or tensors["indices_nonzero_data"][:2] != ("uint4", shape(nonzeros))):
                raise ValueError("Invalid sparse declaration")
            self.sparse[name] = (shape(dims), tensors)
        self.ops = {name: (op, dict(ARG.findall(args))) for _, _, name, op, args in OP.findall(text)}
        if len(self.sparse) != 240:
            raise ValueError("Expected the pinned 24-layer C6s8 encoder")

    def array(self, descriptor):
        import numpy as np

        dtype, dimensions, offset = descriptor
        raw = checked_blob(self.data, offset, dtype, dimensions)
        if dtype == "fp16":
            return np.frombuffer(raw, dtype="<f2").reshape(dimensions)
        packed = np.frombuffer(raw, dtype=np.uint8)
        count = math.prod(dimensions)
        if dtype == "uint1":
            return np.unpackbits(packed, bitorder="little")[:count].reshape(dimensions)
        if dtype == "uint4":
            values = np.empty(packed.size * 2, dtype=np.uint8)
            values[0::2] = packed & 15
            values[1::2] = packed >> 4
            return values[:count].reshape(dimensions)
        raise ValueError("Unsupported tensor read")

    def constant(self, name):
        return self.array(self.constants[name])

    def parameter(self, operation, parameter):
        return self.constant(self.ops[operation][1][parameter])

    def ternary(self, name):
        import numpy as np

        dimensions, args = self.sparse[name]
        rows, columns = dimensions[:2]
        if any(x != 1 for x in dimensions[2:]) or rows % 8 or columns % 64:
            raise ValueError("Unsupported ternary layout")
        mask = self.array(args["indices_mask"]).reshape(rows, columns)
        indices = self.array(args["indices_nonzero_data"]).reshape(-1)
        lut = self.array(args["lut"]).reshape(rows // 8, 16)
        scales = lut[:, 0::2].reshape(rows)
        if (not np.isfinite(scales).all() or (scales <= 0).any()
                or not np.array_equal(lut[:, 1::2], -lut[:, 0::2])
                or int(mask.sum()) != indices.size):
            raise ValueError("Invalid sparse ternary values")
        q = np.ones((rows, columns), dtype=np.uint8)
        positions = np.flatnonzero(mask)
        # The high three bits select the row within the group; the low bit
        # selects sign. Check that every stored index refers to its own row.
        if not np.array_equal(indices >> 1, (positions // columns) % 8):
            raise ValueError("Sparse index points at the wrong row scale")
        q.reshape(-1)[positions] = np.where(indices & 1, 0, 2)
        packed = np.bitwise_or.reduce(
            q.reshape(rows, columns // 16, 16).astype(np.uint32)
            << (2 * np.arange(16, dtype=np.uint32)), axis=-1)
        groups = np.repeat(scales[:, None], columns // 64, axis=1)
        return packed, groups, -groups


def verify_bundle(directory):
    import hashlib
    import json

    directory = Path(directory).resolve()
    manifest = json.loads((directory / "bundle.json").read_text())
    if (manifest.get("export_sha256") != "a287e97719c451b785be2cd01ecc861fcaa010ebaa4ff2841783ec78fcd61503"
            or manifest.get("encoder") != "C6s8" or manifest.get("layout") != "plain"):
        raise ValueError("Expected the pinned final C6s8 export")
    required = {"frontend.json", "frontend.f32bin", "decoder_joint.json", "decoder_joint.f32bin",
                "vocabulary.json", "Encoder.mlmodelc/model.mil", "Encoder.mlmodelc/weights/weight.bin"}
    if not required.issubset(manifest["files"]):
        raise ValueError("Missing required inference assets")
    for name, digest in manifest["files"].items():
        relative = Path(name)
        path = directory / relative
        if relative.is_absolute() or ".." in relative.parts or not path.resolve().is_relative_to(directory):
            raise ValueError("Unsafe bundle asset path")
        with path.open("rb") as stream:
            hasher = hashlib.sha256()
            for chunk in iter(lambda: stream.read(1024 * 1024), b""):
                hasher.update(chunk)
            computed = hasher.hexdigest()
        if computed != digest:
            raise ValueError("Bundle integrity check failed")
    return manifest
