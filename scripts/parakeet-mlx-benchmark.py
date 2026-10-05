#!/usr/bin/env python3
"""Synthetic MLX feasibility experiment; reads only the existing inference bundle."""
import time

PROCESS_START = time.perf_counter()

import argparse
import json
import math
from pathlib import Path
import statistics
import subprocess
import sys
from types import SimpleNamespace

from parakeet_weight_index import WeightIndex, verify_bundle


LINEARS = ("feed_forward1.linear1", "feed_forward1.linear2", "self_attn.linear_q", "self_attn.linear_k",
           "self_attn.linear_v", "self_attn.linear_out", "conv.pointwise_conv1", "conv.pointwise_conv2",
           "feed_forward2.linear1", "feed_forward2.linear2")


def load_weights(bundle):
    import mlx.core as mx
    import numpy as np

    index = WeightIndex(bundle / "Encoder.mlmodelc")
    start = time.perf_counter()
    weights = SimpleNamespace(dt=mx.float16, n_layers=24, sub={}, layers=[], pos={15: []})
    def parameter(op, key):
        return mx.array(index.parameter(op, key))
    for target, op in (("w0", "sub_conv0"), ("dw1", "sub_dw1"), ("pw1", "sub_pw1"),
                       ("dw2", "sub_dw2"), ("pw2", "sub_pw2")):
        weights.sub[target] = mx.array(index.parameter(op, "weight").transpose(0, 2, 3, 1))
        bias_key = "b0" if target == "w0" else target.replace("1", "b1").replace("2", "b2")
        weights.sub[bias_key] = parameter(op, "bias")
    weights.sub["out_w"] = parameter("sub_out", "weight")
    weights.sub["out_b"] = parameter("sub_out", "bias")
    for layer in range(24):
        prefix = f"l{layer}_"
        result = {}
        for norm in ("norm_feed_forward1", "norm_self_att", "norm_conv", "norm_feed_forward2", "norm_out"):
            result[norm] = (parameter(prefix + norm, "gamma"), parameter(prefix + norm, "beta"))
        for target, operation in (("pos_bias_u", "ac"), ("pos_bias_v", "bd_raw")):
            name = index.ops[prefix + operation][1]["x"]
            if index.ops[name][0] != "transpose":
                raise ValueError("Unexpected attention graph")
            add = index.ops[index.ops[name][1]["x"]]
            if add[0] != "add" or add[1]["x"] != prefix + "q":
                raise ValueError("Unexpected positional bias graph")
            bias = index.constant(add[1]["y"])
            if bias.shape != (8, 128):
                raise ValueError("Unexpected positional bias shape")
            result[target] = mx.array(bias)
        for name in LINEARS:
            op = prefix + name.replace(".", "_") + "_mm"
            packed, scales, biases = index.ternary(prefix + name.replace(".", "_") + "_weight")
            arguments = index.ops[op][1]
            bias = index.constant(arguments["bias"]) if "bias" in arguments else np.zeros(packed.shape[0], np.float16)
            result[name] = (mx.array(packed), mx.array(scales), mx.array(biases), mx.array(bias))
        result["dw_w"] = mx.array(index.parameter(prefix + "dw", "weight").transpose(0, 2, 1))
        result["dw_b"] = parameter(prefix + "dw", "bias")
        position = index.parameter(prefix + "bd_raw", "y")
        if position.shape != (1, 8, 128, 375):
            raise ValueError("Unexpected folded position table")
        weights.pos[15].append(mx.array(position[0]))
        weights.layers.append(result)
    mx.eval(weights.sub, weights.layers, weights.pos)
    weights.index = index  # keep mmap alive; no duplicated weights are saved
    return weights, time.perf_counter() - start


class NativeBridge:
    def __init__(self, executable, bundle, fixtures, scratch):
        self.process = subprocess.Popen([str(executable), "native-worker", str(bundle), str(fixtures), str(scratch)],
                                        stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
        try:
            if json.loads(self.process.stdout.readline()) != {"ready": True}:
                raise ValueError("Native bridge failed")
        except Exception:
            self.close()
            raise

    def request(self, operation, duration, **kwargs):
        self.process.stdin.write(json.dumps({"operation": operation, "duration": duration, **kwargs}) + "\n")
        self.process.stdin.flush()
        line = self.process.stdout.readline()
        if not line:
            raise ValueError("Native bridge stopped")
        return json.loads(line)

    def close(self):
        try:
            self.process.stdin.close()
        except BrokenPipeError:
            pass
        try:
            self.process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            self.process.terminate()
            try:
                self.process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait()
        self.process.stdout.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bundle", type=Path, required=True)
    parser.add_argument("--fixtures", type=Path, required=True)
    parser.add_argument("--scratch", type=Path, required=True)
    parser.add_argument("--native", type=Path, required=True)
    parser.add_argument("--background-ane", action="store_true")
    args = parser.parse_args()
    verify_bundle(args.bundle)
    args.scratch.mkdir(parents=True, exist_ok=True)
    bridge = NativeBridge(args.native, args.bundle, args.fixtures, args.scratch)
    ane = None
    try:
        if args.background_ane:
            ane = subprocess.Popen([str(args.native), "fifteen-first", str(args.bundle), str(args.fixtures)],
                                   stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
        import mlx.core as mx
        import numpy as np
        from parakeet_mlx_graph import forward

        weights, packing = load_weights(args.bundle)
        encoder = mx.compile(lambda mel, length: forward(weights, mel, length, 15))
        def transcribe(duration):
            start = time.perf_counter()
            chunks = bridge.request("features", duration)["chunks"]
            lengths = []
            for i, chunk in enumerate(chunks):
                features = np.fromfile(args.scratch / f"features-{i}.bin", dtype="<f4").reshape(128, chunk["frames"])
                mel = np.zeros((128, 1501), np.float16)
                mel[:, :chunk["frames"]] = features
                output, length = encoder(mx.array(mel), mx.array(chunk["valid"], dtype=mx.int32))
                mx.eval(output, length)
                valid = int(length.item())
                np.asarray(output[:, :valid].T, dtype="<f4").tofile(args.scratch / f"encoder-{i}.bin")
                lengths.append(valid)
            match = bridge.request("decode", duration, lengths=lengths)["expected_match"]
            if not match:
                raise ValueError("Synthetic transcript mismatch")
            return {"audio_seconds": duration, "transcription_seconds": time.perf_counter() - start, "expected_match": match}

        fixtures = []
        first_ready = None
        for duration in [14, 4, 7, 18]:
            fixtures.append(transcribe(duration))
            if first_ready is None:
                first_ready = time.perf_counter() - PROCESS_START
                print(json.dumps({"event": "first_transcript", "seconds": first_ready}), flush=True)
        steady = [transcribe(14)["transcription_seconds"] for _ in range(10)]
        peak = mx.get_peak_memory()
        report = {"schema": 1, "strategy": "mlx-with-ane" if ane else "mlx",
                  "first_transcript_ready_seconds": first_ready, "packing_seconds": packing,
                  "fixtures": fixtures, "steady_transcription_median_seconds": statistics.median(steady),
                  "mlx_peak_bytes": peak, "extra_weight_files": 0,
                  "source": "shipped C6s8 MIL + weight.bin; frontend/decoder/vocabulary from the same bundle"}
        if ane:
            # Probe throughout preparation, rather than only during its first
            # few seconds. A cached ANE load can finish before MLX is ready.
            overlapping = []
            deadline = time.monotonic() + 600
            while ane.poll() is None:
                if time.monotonic() >= deadline:
                    raise ValueError("Background ANE preparation timed out")
                overlapping.append(transcribe(14)["transcription_seconds"])
                time.sleep(1)
            output, _ = ane.communicate(timeout=5)
            if ane.returncode:
                raise ValueError("Background ANE benchmark failed")
            report["background_ane"] = json.loads(output)
            report["during_preparation_mlx"] = {
                "samples": len(overlapping),
                "median_seconds": statistics.median(overlapping) if overlapping else None,
                "p95_seconds": sorted(overlapping)[math.ceil(len(overlapping) * .95) - 1] if overlapping else None,
                "max_seconds": max(overlapping) if overlapping else None,
                "probe_interval_seconds": 1,
            }
            after = [transcribe(14)["transcription_seconds"] for _ in range(10)]
            report["post_compilation_mlx_median_seconds"] = statistics.median(after)
            report["mlx_peak_bytes"] = mx.get_peak_memory()
        print(json.dumps(report, sort_keys=True), flush=True)
    finally:
        bridge.close()
        if ane and ane.poll() is None:
            ane.terminate()
            try:
                ane.wait(timeout=5)
            except subprocess.TimeoutExpired:
                ane.kill()
                ane.wait()


if __name__ == "__main__":
    try:
        main()
    except Exception:
        # Do not emit provider/framework errors, input paths or synthetic text.
        print("Synthetic shared-weight MLX benchmark failed.", file=sys.stderr)
        sys.exit(1)
