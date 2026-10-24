"""Smoke of stage B through a real Parakeet model and NeMo's transcription loop
(review implI1-r1 #2-#3). A few train-clean-360 utterances, minutes on a
shared GPU lease:

    ./python-nemo -m lfspk.extract.smoke_hook [--device cuda] [--n 6]

Checks: (1) a zero mask through `transcribe_masked` gives exactly the plain
transcript of the same batch composition; (2) duplicate recordings with
different masks are transcribed independently; (3) a strong mask changes at
least one transcript; (4) a sub-second recording is refused; (5) the hook is
uninstalled afterwards; (6) the model's buffers are the pinned constants;
(7) on CPU, the restored model's preprocessor through the hook equals apply()
exactly. Prints a JSON summary; exits non-zero on failure.
"""

from __future__ import annotations

import argparse
import json
import os
import sys

import numpy as np


def main(argv=None) -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--device", default="cuda")
    ap.add_argument("--n", type=int, default=6)
    a = ap.parse_args(argv)
    import torch

    from lfspk import splits
    from lfspk.harness.asr import load_model, transcribe
    from lfspk.harness.util import load_audio

    from .api import LOG_G_MIN, InferenceConfig, MaskOutput, feature_frames
    from .nemo_hook import MaskedPreprocessor, transcribe_masked

    if a.device == "cuda" and "AGENT_JOBS_VRAM_FRACTION" in os.environ:
        torch.cuda.set_per_process_memory_fraction(float(os.environ["AGENT_JOBS_VRAM_FRACTION"]))
    model = load_model(a.device)
    spk = splits.speakers("train")[:a.n]
    audios = [load_audio(splits.utterances(s)[0]) for s in spk]
    audios = [x[: 16000 * 8] for x in audios if len(x) >= 16000][: a.n]
    order = sorted(range(len(audios)), key=lambda i: len(audios[i]))
    audios = [audios[i] for i in order]  # transcribe_masked sorts by length; keep the same composition
    zero = [MaskOutput(np.zeros((128, feature_frames(len(x))), np.float16), np.ones(feature_frames(len(x)), np.float32))
            for x in audios]
    ref = transcribe(model, audios, batch_size=len(audios))
    got = transcribe_masked(model, audios, zero, InferenceConfig("C1"), batch_size=len(audios))
    ok_zero = all(r["text"] == g["text"] and r["words"] == g["words"] for r, g in zip(ref, got))
    # duplicates with different masks: the second copy fully floored on half its frames
    dup = audios[0].copy()
    t = feature_frames(len(dup))
    strong = np.zeros((128, t), np.float16)
    strong[:, : t // 2] = LOG_G_MIN
    res = transcribe_masked(model, [audios[0], dup], [zero[0], MaskOutput(strong, np.ones(t, np.float32))],
                            InferenceConfig("C1"), batch_size=2)
    ok_dup = res[0]["text"] == ref[0]["text"] and res[1]["text"] != res[0]["text"]
    refused = False
    try:
        transcribe_masked(model, [audios[0][:9000]], [MaskOutput(np.zeros((128, feature_frames(9000)), np.float16),
                                                                  np.ones(feature_frames(9000), np.float32))],
                          InferenceConfig("C1"))
    except ValueError:
        refused = True
    uninstalled = not isinstance(model.preprocessor, MaskedPreprocessor)
    # apply() with the pinned checkpoint constants equals the hook on the restored model, exactly
    from . import constants, frontend
    from .nemo_hook import Row

    w_ck, fb_ck = constants.load()
    f = model.preprocessor.featurizer
    same_constants = bool(np.array_equal(f.window.detach().cpu().numpy(), w_ck)
                          and np.array_equal(f.fb.detach().cpu().numpy().reshape(128, 257), fb_ck))
    # exact parity on one device (CPU): the restored model's own preprocessor, rebuilt on CPU from
    # its config and state (not a deep copy of the CUDA module), vs apply()
    from .nemo_hook import cpu_preprocessor

    mo = MaskOutput(strong, np.ones(t, np.float32))
    hook = MaskedPreprocessor(cpu_preprocessor(model))
    hook.set_rows([Row.make(dup, strong, np.ones(t, np.float32))])
    with torch.no_grad():
        feats, _ = hook(input_signal=torch.from_numpy(dup)[None], length=torch.tensor([len(dup)]))
    ref_apply = frontend.apply(dup, mo, InferenceConfig("C1"))
    apply_max_diff = float(np.abs(feats[0].numpy() - ref_apply).max())
    apply_exact = bool(np.array_equal(feats[0].numpy(), ref_apply))
    out = {"items": len(audios), "zero_mask_identical": ok_zero, "duplicates_independent": ok_dup,
           "short_refused": refused, "uninstalled": uninstalled, "model_uses_pinned_constants": same_constants,
           "hook_vs_apply_cpu_max_abs": apply_max_diff, "hook_equals_apply_cpu": apply_exact,
           "examples": [{"ref": ref[0]["text"], "masked_dup": res[1]["text"]}]}
    print(json.dumps(out, indent=1))
    return 0 if (ok_zero and ok_dup and refused and uninstalled and same_constants and apply_exact) else 1


if __name__ == "__main__":
    sys.exit(main())
