"""Stage A cost survey: parameters, MACs, CPU latency and a Core ML conversion
check for each embedder (DESIGN.md, Candidates).

  ./python[-nemo] -m lfspk.embed.cost --embedder NAME [--coreml]

MACs come from torch.utils.flop_counter.FlopCounterMode (MACs = FLOPs / 2)
on the model trunk, i.e. everything after the acoustic front end (STFT and
mel filterbank are excluded and are a small, fixed cost). They are reported
for 1.0 s and 1.5 s inputs and as a per-second slope. CPU latency is the
median of 20 timed `embed` calls (front end included) after 3 warm-ups, with
1 and 4 intra-op threads, on this x86 host: a proxy, not Apple silicon.

The Core ML check traces the trunk (fixed 1.5 s input) and converts it to an
ML program (macOS 14, float16) with coremltools; on Linux conversion works but
prediction does not, so this establishes op support, not speed or accuracy.
Writes RUNS/W1/survey/cost/<NAME>.json.
"""

from __future__ import annotations

import argparse
import json
import statistics
import time

import numpy as np

from .. import paths
from .embedder import (EcapaSpeechBrain, ReDimNet2, TitaNetNeMo, WeSpeakerTorch, load_embedder)

OUT = paths.RUNS / "W1" / "survey" / "cost"


def split_model(emb):
    """(front_end(batch) -> features, trunk torch.nn.Module(features) -> embedding)."""
    import torch

    if isinstance(emb, EcapaSpeechBrain):
        def fe(batch):
            lens = torch.ones(batch.shape[0])
            return emb.norm(emb.features(batch), lens)

        class Trunk(torch.nn.Module):
            def __init__(self):
                super().__init__()
                self.m = emb.model

            def forward(self, feats):
                return self.m(feats).squeeze(1)
        return fe, Trunk()
    if isinstance(emb, TitaNetNeMo):
        model = emb.model

        def fe(batch):
            lens = torch.full((batch.shape[0],), batch.shape[1], dtype=torch.long)
            feats, feat_len = model.preprocessor(input_signal=batch, length=lens)
            return feats[:, :, : int(feat_len.max())]  # drop pad_to padding; the trunk sees the true length

        class Trunk(torch.nn.Module):
            def __init__(self):
                super().__init__()
                self.encoder, self.decoder = model.encoder, model.decoder

            def forward(self, feats):
                lens = torch.full((feats.shape[0],), feats.shape[2], dtype=torch.long)
                enc, enc_len = self.encoder(audio_signal=feats, length=lens)
                return self.decoder(encoder_output=enc, length=enc_len)[1]
        return fe, Trunk()
    if isinstance(emb, WeSpeakerTorch):
        class Trunk(torch.nn.Module):
            def __init__(self):
                super().__init__()
                self.m = emb.model

            def forward(self, feats):
                out = self.m(feats)
                return out[-1] if isinstance(out, tuple) else out
        return emb.fbank, Trunk()
    if isinstance(emb, ReDimNet2):
        wrap = emb.model

        class Trunk(torch.nn.Module):
            def __init__(self):
                super().__init__()
                self.w = wrap

            def forward(self, spec):
                w = self.w
                x = spec.unsqueeze(1) if spec.ndim == 3 else spec
                out = w.backbone(x)
                if out.ndim == 4:
                    b, c, f, t = out.size()
                    out = out.reshape(b, c * f, t)
                if w.before_pool_offset is not None:
                    out = out[:, :, w.before_pool_offset:]
                out = w.linear(w.bn(w.pool(out)))
                return w.bn2(out) if w.bn2 is not None else out

        def fe(batch):
            x = batch
            if wrap.pad_right_samples is not None:
                x = torch.nn.functional.pad(x, (0, wrap.pad_right_samples))
            return wrap.spec(x)
        return fe, Trunk()
    raise TypeError(type(emb))


def trunk_macs(fe, trunk, seconds: float) -> float:
    import torch
    from torch.utils.flop_counter import FlopCounterMode

    x = torch.from_numpy((np.random.default_rng(0).standard_normal((1, int(seconds * 16000))) * 0.05)
                         .astype(np.float32))
    with torch.inference_mode():
        feats = fe(x)
        with FlopCounterMode(display=False) as counter:
            trunk(feats)
    return counter.get_total_flops() / 2.0


def latency(emb, seconds: float, threads: int, runs: int = 20) -> float:
    import torch

    torch.set_num_threads(threads)
    x = (np.random.default_rng(1).standard_normal(int(seconds * 16000)) * 0.05).astype(np.float32)
    for _ in range(3):
        emb.embed(x)
    times = []
    for _ in range(runs):
        t = time.perf_counter()
        emb.embed(x)
        times.append(time.perf_counter() - t)
    return statistics.median(times) * 1000.0


def _patch_coremltools_cast() -> None:
    """Compatibility shim, not a model change: coremltools 9's torch frontend
    casts a folded length-1 constant with int(ndarray), which numpy >= 2.4
    rejects. Cast its single element instead."""
    from coremltools.converters.mil.frontend.torch import ops

    if getattr(ops._cast, "_lfspk_patched", False):
        return
    original = ops._cast

    def cast(context, node, dtype, dtype_name):
        safe = type("SafeCast", (), {"__new__": lambda cls, v: dtype(np.asarray(v).reshape(-1)[0])})
        return original(context, node, safe, dtype_name)

    cast._lfspk_patched = True
    ops._cast = cast


def coreml_check(fe, trunk) -> dict:
    import torch

    try:
        import coremltools as ct
    except ImportError as e:  # pragma: no cover
        return {"converted": False, "error": f"coremltools unavailable: {e}"}
    _patch_coremltools_cast()
    x = torch.from_numpy((np.random.default_rng(2).standard_normal((1, 24000)) * 0.05).astype(np.float32))
    with torch.no_grad():
        feats = fe(x).clone()
    try:
        with torch.no_grad():
            traced = torch.jit.trace(trunk.eval(), feats, check_trace=False)
        ml = ct.convert(traced, inputs=[ct.TensorType(name="feats", shape=tuple(feats.shape))],
                        convert_to="mlprogram", minimum_deployment_target=ct.target.macOS14,
                        compute_precision=ct.precision.FLOAT16)
        ops = sorted({op.op_type for f in ml._mil_program.functions.values() for op in f.operations})
        return {"converted": True, "mil_ops": ops}
    except Exception as e:  # report, do not hide
        return {"converted": False, "error": f"{type(e).__name__}: {str(e)[:500]}"}


def main(argv=None) -> None:
    ap = argparse.ArgumentParser(prog="lfspk.embed.cost")
    ap.add_argument("--embedder", required=True)
    ap.add_argument("--coreml", action="store_true")
    args = ap.parse_args(argv)
    paths.require_mount()
    emb = load_embedder(args.embedder, "cpu")
    fe, trunk = split_model(emb)
    m1, m15 = trunk_macs(fe, trunk, 1.0), trunk_macs(fe, trunk, 1.5)
    out = {"embedder": emb.name, "weights_sha256": emb.weights_sha256, "params": emb.params, "dim": emb.dim,
           "trunk_macs_1.0s": m1, "trunk_macs_1.5s": m15, "trunk_macs_per_s_slope": (m15 - m1) / 0.5,
           "latency_ms": {f"{s}s_{t}thr": latency(emb, s, t) for s in (1.0, 1.5) for t in (1, 4)}}
    if args.coreml:
        out["coreml"] = coreml_check(fe, trunk)
    OUT.mkdir(parents=True, exist_ok=True)
    (OUT / f"{emb.name}.json").write_text(json.dumps(out, indent=1))
    print(json.dumps(out))


if __name__ == "__main__":
    main()
