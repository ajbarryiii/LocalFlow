"""W1 frame scorer: sliding-window speaker embeddings, cohort normalisation,
window-to-frame mapping and a small logistic head (DESIGN.md, Stages B-C).

`EmbeddingScorer` implements `lfspk.api.TargetSpeakerScorer`. Its profile is
`profile.EmbProfile` (centroids and counts only). Enrollment and update see
each dictation once and keep only the updated centroid.

Window layout: windows of `window_s` every `hop_s` seconds from the start, plus
one window ending at the last sample when the hop grid does not reach it; a
recording no longer than one window gives a single window over all of it, and
one shorter than `embedder.MIN_SAMPLES` gives none. A window is embedded only
if at least `min_speech` of its frames pass the energy gate.

Window score: max over centroids of the cosine (`norm = "raw"`), or of the
AS-norm score against the shipped train-split cohort (`norm = "asnorm"`;
profile side vs the full-utterance cohort, window side vs the cohort embedded
at the window length; top-K means).

Frame features (all per 10 ms frame): `score` = Hann-weighted mean of the
scores of the embedded windows covering the frame (frames covered by none get
the recording's lowest window score, or `FALLBACK[norm]` if no window was
embedded); `raw` = the same for raw cosine; `local_max` / `local_min` = max /
min of the scores of windows covering the frame (fallback as above);
`covered` = 1 if some embedded window covers the frame; `rel_energy` = frame
energy minus the recording's 95th-percentile frame energy (dB, clipped to
[-60, 10]); `snr` = frame energy minus the noise floor (dB, clipped to [0, 80]);
`gate` = energy-gate speech flag; `utt_mean` / `utt_max` = mean / max window
score of the recording.

Frame output = sigmoid(head(features)), where the head is a logistic
regression over a named subset of features with fixed standardisation. The
default head maps `score` alone through a fixed logistic.
"""

from __future__ import annotations

import json
from dataclasses import asdict, dataclass, field
from pathlib import Path
from typing import Sequence

import numpy as np

from .. import paths
from ..api import FRAME_SAMPLES, SAMPLE_RATE, CostReport, check_audio, check_scores, frame_count
from . import norm as N
from .audio import frame_energy_db, noise_floor_db, speech_gate
from .embedder import MIN_SAMPLES, Embedder, load_embedder
from .profile import EmbProfile

FALLBACK = {"raw": -1.0, "asnorm": -5.0}  # at or below the lowest score a window can plausibly get
FEATURES = ("score", "raw", "local_max", "local_min", "covered", "rel_energy", "snr", "gate", "utt_mean", "utt_max")


@dataclass(frozen=True)
class WindowConfig:
    window_s: float = 1.5
    hop_s: float = 0.25
    min_speech: float = 0.3


@dataclass(frozen=True)
class UpdateConfig:
    rule: str = "robust"  # "naive", "gated", "robust" or "anchored"
    window_gate: float = 0.0  # window kept if its score >= this (score units of ScorerConfig.norm)
    dictation_gate: float = 0.0  # dictation accepted if mean kept-window score >= this
    min_kept: float = 0.5  # and at least this fraction of embedded windows were kept
    n_cap: int = 50  # an accepted dictation has weight >= 1 / (n_cap + 1)
    trim_mads: float = 3.0  # robust enrollment: drop windows below median - trim_mads * MAD
    anchor_gate: float = -1.0  # anchored: dictation rejected if cos(d, anchor) < this (raw cosine)
    drift_floor: float = -1.0  # anchored: update rejected if cos(new direction, anchor) < this


UPDATE_WINDOW = WindowConfig(1.5, 0.25, 0.3)


@dataclass(frozen=True)
class Head:
    features: tuple[str, ...] = ("score",)
    mean: tuple[float, ...] = (0.0,)
    scale: tuple[float, ...] = (1.0,)
    coef: tuple[float, ...] = (1.0,)
    intercept: float = 0.0

    def __post_init__(self):
        n = len(self.features)
        if not (len(self.mean) == len(self.scale) == len(self.coef) == n) or not set(self.features) <= set(FEATURES):
            raise ValueError("inconsistent head")

    def logits(self, feats: dict[str, np.ndarray]) -> np.ndarray:
        z = np.full(next(iter(feats.values())).shape, self.intercept, np.float64)
        for f, m, s, c in zip(self.features, self.mean, self.scale, self.coef):
            z += c * (feats[f] - m) / s
        return z

    def to_json(self) -> str:
        return json.dumps(asdict(self))

    @classmethod
    def from_json(cls, text: str) -> "Head":
        d = json.loads(text)
        return cls(**{k: tuple(v) if isinstance(v, list) else v for k, v in d.items()})


@dataclass(frozen=True)
class ScorerConfig:
    embedder: str
    window: WindowConfig = field(default_factory=WindowConfig)  # scoring windows
    norm: str = "asnorm"
    top_k: int = 200
    update: UpdateConfig = field(default_factory=UpdateConfig)
    head: Head = field(default_factory=Head)
    name: str = ""
    # Enrollment and update windows: background work, fixed across scoring
    # configurations so that one set of calibrated gates serves them all.
    update_window: WindowConfig = field(default_factory=lambda: UPDATE_WINDOW)

    def __post_init__(self):
        if self.norm not in FALLBACK:
            raise ValueError(f"norm must be one of {sorted(FALLBACK)}")
        if self.update.rule not in ("naive", "gated", "robust", "anchored"):
            raise ValueError("unknown update rule")


@dataclass(frozen=True)
class Cohort:
    """Shipped normalisation cohort: L2-normalised train-split embeddings."""

    full: np.ndarray  # (M, D) full utterances (profile side)
    window: np.ndarray  # (M, D) segments of the scoring window length
    update: np.ndarray | None = None  # (M, D) segments of the update window length; None = same as window

    @property
    def update_or_window(self) -> np.ndarray:
        return self.window if self.update is None else self.update

    @classmethod
    def from_survey(cls, embedder: str, window_s: float, root: Path | None = None,
                    update_s: float | None = None) -> "Cohort":
        """Cohort embedded by Stage A (`survey embed`), train split only."""
        import csv

        d = (root or paths.RUNS / "W1" / "survey") / "emb" / embedder
        full = np.load(d / "cohort_full.f32.npy")
        seg = np.load(d / "cohort_seg.f32.npy")
        with open(d / "cohort_seg.tsv", newline="") as f:
            lens = np.array([float(r["len_s"]) for r in csv.DictReader(f, delimiter="\t")])
        out = []
        for L in (window_s, update_s if update_s is not None else window_s):
            if not np.any(lens == L):
                raise ValueError(f"no cohort segments of {L} s for {embedder}")
            out.append(seg[lens == L])
        return cls(full, out[0], None if update_s in (None, window_s) else out[1])


def window_layout(num_samples: int, cfg: WindowConfig) -> list[tuple[int, int]]:
    """(start, length) in samples of every window (see module docstring)."""
    if num_samples < MIN_SAMPLES:
        return []
    L = int(round(cfg.window_s * SAMPLE_RATE))
    H = int(round(cfg.hop_s * SAMPLE_RATE))
    if num_samples <= L:
        return [(0, num_samples)]
    starts = list(range(0, num_samples - L + 1, H))
    if starts[-1] + L < num_samples:
        starts.append(num_samples - L)
    return [(s, L) for s in starts]


def _frame_span(start: int, length: int) -> tuple[int, int]:
    return start // FRAME_SAMPLES, (start + length + FRAME_SAMPLES - 1) // FRAME_SAMPLES


@dataclass
class Windows:
    spans: list[tuple[int, int]]  # embedded windows, (start, length) in samples
    emb: np.ndarray  # (n, D)
    energy_db: np.ndarray  # per frame
    gate: np.ndarray  # per frame
    n_layout: int  # windows in the layout before the speech filter


def embed_windows(embedder: Embedder, audio: np.ndarray, cfg: WindowConfig) -> Windows:
    energy = frame_energy_db(audio)
    gate = speech_gate(energy)
    layout = window_layout(audio.size, cfg)
    keep = []
    for start, length in layout:
        f0, f1 = _frame_span(start, length)
        if gate[f0:f1].mean() >= cfg.min_speech:
            keep.append((start, length))
    emb = (embedder.embed_batch([audio[s:s + n] for s, n in keep]) if keep
           else np.zeros((0, embedder.dim), np.float32))
    return Windows(keep, emb, energy, gate, len(layout))


def _hann(n: int) -> np.ndarray:
    return np.hanning(n + 2)[1:-1] if n > 0 else np.zeros(0)


class EmbeddingScorer:
    """TargetSpeakerScorer over a frozen pretrained embedder (see module doc)."""

    def __init__(self, config: ScorerConfig, embedder: Embedder | None = None, cohort: Cohort | None = None,
                 device: str = "cpu", cache_windows: int = 0):
        """`cache_windows` > 0 keeps the scoring-window embeddings of that many
        recent recordings (keyed by a hash of the audio): the harness scores
        each test mixture with up to 12 profiles, and the embeddings do not
        depend on the profile. Results are identical; only time changes, so
        latency must be measured with the cache off (0, the default)."""
        self.config = config
        self.cache_windows = int(cache_windows)
        self._cache: dict = {}
        self.name = config.name or f"w1-{config.embedder}-{config.norm}"
        self.embedder = embedder or load_embedder(config.embedder, device)
        if self.embedder.name != config.embedder:
            raise ValueError("embedder does not match config")
        if config.norm == "asnorm":
            if cohort is None:
                cohort = Cohort.from_survey(config.embedder, config.window.window_s,
                                            update_s=config.update_window.window_s)
            if min(cohort.full.shape[0], cohort.window.shape[0], cohort.update_or_window.shape[0]) < config.top_k:
                raise ValueError("cohort smaller than top_k")
        self.cohort = cohort

    # ------------------------------------------------------------ scoring core
    def window_scores(self, profile: EmbProfile, emb: np.ndarray, kind: str = "score") -> tuple[np.ndarray, np.ndarray]:
        """(score in config.norm units, raw cosine), max over centroids, per
        window. `kind` = "score" for scoring windows, "update" for enrollment
        and update windows (AS-norm uses the cohort of that window length)."""
        if emb.shape[0] == 0:
            return np.zeros(0), np.zeros(0)
        dirs = profile.directions
        raw = emb @ dirs.T  # (n, K)
        if self.config.norm == "raw":
            s = raw
        else:
            mu_p, sd_p = N.cohort_stats(dirs, self.cohort.full, self.config.top_k)
            wc = self.cohort.window if kind == "score" else self.cohort.update_or_window
            mu_w, sd_w = N.cohort_stats(emb, wc, self.config.top_k)
            s = N.snorm(raw, mu_p[None, :], sd_p[None, :], mu_w[:, None], sd_w[:, None])
        return s.max(axis=1).astype(np.float64), raw.max(axis=1).astype(np.float64)

    def frame_features(self, profile: EmbProfile, audio: np.ndarray, windows: Windows | None = None) -> dict:
        check_audio(audio)
        w = windows or self._scoring_windows(audio)
        n = frame_count(audio.size)
        s, r = self.window_scores(profile, w.emb)
        fb = float(s.min()) if s.size else FALLBACK[self.config.norm]
        fb_raw = float(r.min()) if r.size else FALLBACK["raw"]
        num, num_raw, den = np.zeros(n), np.zeros(n), np.zeros(n)
        lmax, lmin = np.full(n, -np.inf), np.full(n, np.inf)
        for (start, length), si, ri in zip(w.spans, s, r):
            f0, f1 = _frame_span(start, length)
            f1 = min(f1, n)
            h = _hann(f1 - f0)
            num[f0:f1] += h * si
            num_raw[f0:f1] += h * ri
            den[f0:f1] += h
            lmax[f0:f1] = np.maximum(lmax[f0:f1], si)
            lmin[f0:f1] = np.minimum(lmin[f0:f1], si)
        covered = den > 0
        safe = np.where(covered, den, 1.0)
        # Uncovered frames: the recording's lowest window score if the energy
        # gate calls them speech, else the fixed low fallback (silence scores low).
        low, low_raw = FALLBACK[self.config.norm], FALLBACK["raw"]
        fb = np.where(w.gate, fb, low) if w.gate.size == n else np.full(n, low)
        fb_raw = np.where(w.gate, fb_raw, low_raw) if w.gate.size == n else np.full(n, low_raw)
        floor = noise_floor_db(w.energy_db)
        p95 = float(np.percentile(w.energy_db, 95)) if n else 0.0
        return {
            "score": np.where(covered, num / safe, fb),
            "raw": np.where(covered, num_raw / safe, fb_raw),
            "local_max": np.where(covered, lmax, fb),
            "local_min": np.where(covered, lmin, fb),
            "covered": covered.astype(np.float64),
            "rel_energy": np.clip(w.energy_db - p95, -60.0, 10.0).astype(np.float64),
            "snr": np.clip(w.energy_db - floor, 0.0, 80.0).astype(np.float64),
            "gate": w.gate.astype(np.float64),
            "utt_mean": np.full(n, float(s.mean()) if s.size else low),
            "utt_max": np.full(n, float(s.max()) if s.size else low),
        }

    def _scoring_windows(self, audio: np.ndarray) -> Windows:
        if self.cache_windows <= 0:
            return embed_windows(self.embedder, audio, self.config.window)
        import hashlib

        key = (hashlib.sha1(audio.tobytes()).hexdigest(), audio.size)
        if key in self._cache:
            self._cache[key] = self._cache.pop(key)  # most recently used last
            return self._cache[key]
        w = embed_windows(self.embedder, audio, self.config.window)
        self._cache[key] = w
        while len(self._cache) > self.cache_windows:
            self._cache.pop(next(iter(self._cache)))
        return w

    def score(self, profile: EmbProfile, audio: np.ndarray) -> np.ndarray:
        n = frame_count(check_audio(audio).size)
        if n == 0:
            return np.zeros(0, np.float32)
        z = self.config.head.logits(self.frame_features(profile, audio))
        out = (1.0 / (1.0 + np.exp(-np.clip(z, -50, 50)))).astype(np.float32)
        return check_scores(out, audio.size)

    # ------------------------------------------------------- enroll and update
    def dictation_embedding(self, windows: Windows) -> np.ndarray | None:
        if windows.emb.shape[0] == 0:
            return None
        m = windows.emb.mean(axis=0)
        return m / np.linalg.norm(m)

    def enroll(self, utterances: Sequence[np.ndarray]) -> EmbProfile:
        if len(utterances) == 0:
            raise ValueError("enroll needs at least one dictation")
        return self.enroll_windows([embed_windows(self.embedder, check_audio(u), self.config.update_window)
                                    for u in utterances])

    def update(self, profile: EmbProfile, utterance: np.ndarray) -> EmbProfile:
        return self.update_windows(profile, embed_windows(self.embedder, check_audio(utterance),
                                                          self.config.update_window))

    def enroll_windows(self, wins: Sequence[Windows]) -> EmbProfile:
        """`enroll` from already embedded dictations (identical result).
        Stored centroid = mean of the unit dictation embeddings. For "robust"
        and "anchored", windows of all dictations are first trimmed against
        their spherical median (`robust_keep`), and a dictation's embedding is
        the normalised mean of its kept windows; dictations left without
        windows are skipped. "anchored" also stores the enrollment direction
        as the profile's fixed anchor."""
        rule = self.config.update.rule
        if rule in ("robust", "anchored"):
            sizes = [w.emb.shape[0] for w in wins]
            all_emb = np.concatenate([w.emb for w in wins]) if wins else np.zeros((0, 0))
            if all_emb.shape[0] == 0:
                raise ValueError("no speech in the enrollment dictations")
            keep = robust_keep(all_emb, self.config.update.trim_mads)
            ds, off = [], 0
            for n in sizes:
                k = keep[off:off + n]
                if k.any():
                    ds.append(_unit(all_emb[off:off + n][k].mean(axis=0)))
                off += n
        else:
            ds = [d for d in (self.dictation_embedding(w) for w in wins) if d is not None]
        if not ds:
            raise ValueError("no speech in the enrollment dictations")
        m = np.mean(ds, axis=0)
        p = EmbProfile(self.config.embedder, m[None, :], np.array([len(ds)]), seen=len(wins), accepted=len(ds),
                       anchor=_unit(m) if rule == "anchored" else None)
        return p.quantised()

    def update_windows(self, profile: EmbProfile, w: Windows) -> EmbProfile:
        """`update` from an already embedded dictation (identical result).
        naive: m <- m + (d - m) / (n + 1) for every dictation with speech (an
        exact running mean). gated / robust / anchored: windows scoring below
        `window_gate` are dropped; the dictation is accepted only if at least
        `min_kept` of its windows remain and their mean score reaches
        `dictation_gate`; then d = normalised mean of the kept windows and
        m <- m + (d - m) / (min(n, n_cap) + 1). anchored additionally rejects
        the dictation if cos(d, anchor) < `anchor_gate`, or if the updated
        direction would fall below `drift_floor` in cosine to the anchor, so
        the profile can never drift further than that from enrollment."""
        if not isinstance(profile, EmbProfile) or profile.embedder != self.config.embedder:
            raise TypeError("profile from a different scorer")
        cfg = self.config.update
        m, n = profile.centroids[0].astype(np.float64), int(profile.counts[0])
        new = None
        if w.emb.shape[0] > 0:
            if cfg.rule == "naive":
                d = self.dictation_embedding(w)
                new = m + (d - m) / (n + 1)
            else:
                s, _ = self.window_scores(profile, w.emb, kind="update")
                if accepts(s, cfg):
                    kept = s >= cfg.window_gate
                    d = _unit(w.emb[kept].mean(axis=0).astype(np.float64))
                    cand = m + (d - m) / (min(n, cfg.n_cap) + 1)
                    if cfg.rule != "anchored":
                        new = cand
                    else:
                        a = profile.anchor.astype(np.float64)
                        if d @ a >= cfg.anchor_gate and _unit(cand) @ a >= cfg.drift_floor:
                            new = cand
        if new is None:
            p = EmbProfile(profile.embedder, profile.centroids, profile.counts, seen=profile.seen + 1,
                           accepted=profile.accepted, anchor=profile.anchor)
        else:
            p = EmbProfile(profile.embedder, new[None, :], np.array([n + 1]), seen=profile.seen + 1,
                           accepted=profile.accepted + 1, anchor=profile.anchor)
        return p.quantised()

    # ------------------------------------------------------------------- cost
    def cost(self) -> CostReport:
        """Per-second scoring MACs = (scoring-window trunk MACs + window-side
        cohort dot products + profile dot product) / hop, plus a per-call
        constant for the profile-side cohort statistics (M_full x D per
        centroid), stated in the notes. update_macs = the update windows of a
        10 s dictation (trunk + cohort + profile products) plus that constant."""
        from .cost import OUT as COST_OUT

        cfg = self.config
        d = self.embedder.dim
        cost_file = COST_OUT / f"{cfg.embedder}.json"
        c = json.loads(cost_file.read_text()) if cost_file.is_file() else {}

        def trunk(window_s: float) -> float:
            return float(c.get(f"trunk_macs_{window_s}s", float("nan")))

        coh = self.cohort
        score_cohort = 0 if coh is None else coh.window.shape[0] * d
        update_cohort = 0 if coh is None else coh.update_or_window.shape[0] * d
        profile_cohort = 0 if coh is None else coh.full.shape[0] * d  # per call, per centroid
        cohort_rows = 0 if coh is None else coh.full.shape[0] + coh.window.shape[0] + (
            0 if coh.update is None else coh.update.shape[0])
        head_params = 2 * len(cfg.head.features) + 1
        n_upd_10s = len(window_layout(10 * SAMPLE_RATE, cfg.update_window))
        anchored = cfg.update.rule == "anchored"
        return CostReport(
            params=int(self.embedder.params + cohort_rows * d + head_params),
            macs_per_audio_second=(trunk(cfg.window.window_s) + score_cohort + d) / cfg.window.hop_s,
            update_macs=n_upd_10s * (trunk(cfg.update_window.window_s) + update_cohort + d) + profile_cohort + 2 * d,
            profile_bytes=EmbProfile.size_bytes(d, 1, anchored),
            notes=(f"{cfg.embedder}: trunk MACs per {cfg.window.window_s} s scoring window and per "
                   f"{cfg.update_window.window_s} s update window from the Stage A cost survey (front end "
                   f"excluded); worst case, every window embedded; plus {profile_cohort} MACs once per score call "
                   f"(profile-side cohort statistics); params include {cohort_rows} shipped cohort embeddings x {d}"),
        )


def _unit(x: np.ndarray) -> np.ndarray:
    return x / np.linalg.norm(x)


def dictation_statistic(window_scores: np.ndarray, window_gate: float, min_kept: float) -> float:
    """The gated rules' dictation statistic: the mean float64 score of the
    windows at or above `window_gate`, or -inf when fewer than `min_kept` of
    the windows (or none) are kept. Calibration and updates both use this."""
    s = np.asarray(window_scores, np.float64)
    if s.size == 0:
        return -np.inf
    kept = s >= window_gate
    return float(s[kept].mean()) if kept.any() and kept.mean() >= min_kept else -np.inf


def accepts(window_scores: np.ndarray, cfg: "UpdateConfig") -> bool:
    """The gated rules' acceptance decision (before any anchor check)."""
    stat = dictation_statistic(window_scores, cfg.window_gate, cfg.min_kept)
    return bool(np.isfinite(stat) and stat >= cfg.dictation_gate)


def robust_keep(emb: np.ndarray, trim_mads: float, iters: int = 50) -> np.ndarray:
    """Boolean mask of the unit rows to keep: spherical median (Weiszfeld),
    then rows whose cosine to it is at least median - trim_mads * MAD (scaled
    MAD); at least half of the rows are always kept."""
    x = emb.astype(np.float64)
    m = _unit(x.mean(axis=0))
    for _ in range(iters):
        dist = np.linalg.norm(x - m, axis=1)
        new = _unit((x / np.maximum(dist, 1e-6)[:, None]).sum(axis=0))
        done = np.linalg.norm(new - m) < 1e-7
        m = new
        if done:
            break
    cos = x @ m
    med = np.median(cos)
    mad = np.median(np.abs(cos - med)) * 1.4826
    keep = cos >= med - trim_mads * mad
    if keep.sum() < (len(cos) + 1) // 2:
        keep = cos >= np.sort(cos)[len(cos) // 2]
    return keep


def robust_mean(emb: np.ndarray, trim_mads: float) -> np.ndarray:
    """Normalised mean of the rows `robust_keep` keeps."""
    return _unit(emb[robust_keep(emb, trim_mads)].astype(np.float64).mean(axis=0))
