"""MixtureSource over W0's scenario generator (lfspk.harness.mix), train split only.

W3 renders nothing itself: every mixture is `MixtureGenerator("train").render`
with a target utterance W3 picks from the target speaker's mixture pool
(enrollment.partition_speaker), so enrollment and mixture never share a pool.
Interferers, rooms, levels, noise and devices are W0's, drawn from the whole
train split (the same_chapter speakers included: they are excluded only as
targets).

Per example, from the caller's RNG (DESIGN.md section 5):
- scenario: S0..S4 with `scenario_weights` (default uniform, 0.2 each);
- target speaker: uniform over target-eligible speakers, then a mixture-pool
  utterance of W0's target length (3-20 s) uniformly;
- device: "headset" with p_headset (default 0: the frozen sets score built-in
  microphone mixtures), else "builtin";
- RIR mode: "mixed" with p_mixed_rir (default 0.2; W0's secondary mode applies
  to every role at equal rates, so it adds acoustic variety without a role cue),
  else "coherent";
- render seed: a 62-bit integer.
"""

from __future__ import annotations

from typing import Mapping, Sequence

import numpy as np

from .data import Mixture
from .enrollment import SpeakerPartition, target_eligible


def interferer_speakers(meta: dict) -> tuple[str, ...]:
    """LibriSpeech speakers of a W0 mixture's interferers (TV programmes may hold
    several or, for us-gov speech, none)."""
    out: list[str] = []
    for it in meta.get("interferers", []):
        if it.get("speaker"):
            out.append(str(it["speaker"]))
        for s in it.get("speakers", []) or []:
            out.append(str(s))
    return tuple(dict.fromkeys(out))


class W0Source:
    SCENARIOS = ("S0", "S1", "S2", "S3", "S4")

    def __init__(self, partitions: Mapping[str, SpeakerPartition], scenario_weights: Sequence[float] | None = None,
                 p_headset: float = 0.0, p_mixed_rir: float = 0.2, split: str = "train", generator=None):
        if split != "train":
            raise ValueError("PVAD training mixtures come from the train split only")
        if generator is None:
            from lfspk.harness.mix import MixtureGenerator

            generator = MixtureGenerator("train")
        self.gen = generator
        w = np.ones(5) if scenario_weights is None else np.asarray(scenario_weights, dtype=float)
        if w.shape != (5,) or (w < 0).any() or w.sum() <= 0:
            raise ValueError("scenario_weights needs five non-negative weights")
        self.weights = w / w.sum()
        self.p_headset = float(p_headset)
        self.p_mixed_rir = float(p_mixed_rir)
        lo, hi = 3.0, 20.0
        try:
            from lfspk.harness.mix import TARGET_SECONDS

            lo, hi = TARGET_SECONDS
        except ImportError:  # a stand-in generator in tests
            pass
        by_id = self.gen.corpus.utterance_by_id
        self.pools: dict[str, list[str]] = {}
        for spk, part in sorted(partitions.items()):
            if not target_eligible(part):
                continue
            pool = sorted(u for u in part.mixture if lo <= by_id[u].seconds <= hi)
            if pool:
                self.pools[spk] = pool
        self.targets = sorted(self.pools, key=int)
        if not self.targets:
            raise ValueError("no eligible target speakers")

    def sample(self, rng: np.random.Generator) -> Mixture:
        scenario = self.SCENARIOS[int(rng.choice(5, p=self.weights))]
        spk = self.targets[int(rng.integers(len(self.targets)))]
        pool = self.pools[spk]
        utt = pool[int(rng.integers(len(pool)))]
        seed = int(rng.integers(2**62))
        device = "headset" if rng.random() < self.p_headset else "builtin"
        mode = "mixed" if rng.random() < self.p_mixed_rir else "coherent"
        m = self.gen.render(scenario, seed, target=utt, device=device, rir_mode=mode)
        meta = m.meta
        if meta["target"]["utt"] != utt or str(meta["target"]["speaker"]) != spk:
            raise AssertionError("W0 rendered a different target than requested")
        speakers = (spk,) + tuple(s for s in interferer_speakers(meta) if s != spk)
        return Mixture(m.audio, np.asarray(m.labels), spk, (utt,), speakers, scenario, device,
                       {"seed": seed, "rir_mode": mode, "w0_scenario": meta.get("scenario")})
