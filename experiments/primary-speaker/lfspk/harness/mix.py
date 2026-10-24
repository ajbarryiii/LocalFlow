"""Deterministic scenario mixtures S0-S4 (DESIGN.md sections 3-6).

    from lfspk.harness.mix import MixtureGenerator, MixtureSampler
    gen = MixtureGenerator("train")
    m = gen.render("S4", seed=123)            # one mixture, random target
    m.audio, m.target, m.interferers, m.noise, m.labels, m.meta

    sampler = MixtureSampler("train", base_seed=0)   # on-the-fly training stream
    m = sampler[17]                                  # deterministic per index
    m, enroll = sampler.with_enrollment(17, n=5)     # plus 5 dictations of the target speaker

A mixture is a pure function of (split, scenario, seed, target, device, corpus
index hashes). Draws are split into a *base* stream (target placement, room,
ambience, levels, device) shared by every scenario with the same seed, and a
*scenario* stream (interferers), so S0-S4 rendered from one seed and target
differ only in their interference: the frozen sets are paired across scenarios
and a contaminated enrollment dictation differs from its clean twin only by
the added talker.

Everything is aligned to the 10 ms frame grid: offsets, cuts and lengths are
whole frames, so dry activity shifts exactly into the mixture timeline.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from functools import lru_cache
from pathlib import Path
from typing import Any, Sequence

import numpy as np

from ..api import FRAME_SAMPLES
from . import channels
from .activity import compose_labels, place, runs
from .forced import GAP_S, activity_from_alignment
from .corpora import Corpus, Utterance, load_rir
from .util import active_level_db, convolve, load_audio, mean_level_db, pink_noise, rng_for, seconds_to_frames, sha256_file, stable_int

SCENARIOS = ("S0", "S1", "S2", "S3", "S4")
RIR_MODES = ("coherent", "mixed")  # primary: one room for every source; secondary: provenance-balanced pools
PEAK_LIMIT = 0.95

# Ranges (DESIGN.md section 3.1). SIR is per interferer, dB, target over interferer.
SIR_RANGE = {"S1": (3.0, 18.0), "S2": (0.0, 15.0), "S3": (-6.0, 9.0), "S4": (-2.0, 10.0)}
SNR_RANGE = {"S0": (15.0, 40.0), "S1": (10.0, 25.0), "S2": (15.0, 40.0), "S3": (15.0, 40.0), "S4": (15.0, 40.0)}
TARGET_LEVEL_DBFS = (-34.0, -20.0)
TARGET_SECONDS = (3.0, 20.0)
LEAD_SECONDS = (0.3, 1.0)
FAR_DISTANCE = {"S1": (1.5, 5.0), "S2": (1.5, 4.0), "S4": (1.0, 3.0), "event": (1.0, 5.0)}
MIN_ACTIVE_FRAMES = 50  # an interferer contributes at least 0.5 s of speech


@dataclass
class Mixture:
    """One rendered mixture. All arrays share the timeline; audio arrays are
    float32 of `len(audio)` samples, frame arrays have frame_count(len(audio))."""

    audio: np.ndarray
    target: np.ndarray  # target image at the microphone (reverberant, coloured, levelled)
    target_dry: np.ndarray  # placed dry target track (same gain as the image)
    interferers: list[np.ndarray]  # interferer images at the microphone
    interferers_dry: list[np.ndarray]  # placed dry interferer *speech* tracks (TV: without music)
    noise: np.ndarray  # ambience + noise event + device self-noise, at the microphone
    labels: np.ndarray  # uint8 per frame: 0 none, 1 target, 2 interferer, 3 both
    target_active: np.ndarray  # bool per frame
    interferer_active: np.ndarray  # bool per frame, OR over interferers
    interferer_actives: list[np.ndarray]  # bool per frame, per interferer
    meta: dict[str, Any] = field(default_factory=dict)
    noise_parts: dict[str, np.ndarray] = field(default_factory=dict)  # "ambience", "event", "self"; they sum to `noise`


RELATIONS = ("cross_project", "same_project_cross_chapter", "same_chapter")


@dataclass(frozen=True)
class SpeakerPlan:
    speaker: str
    test_chapter: str
    test_project: str
    targets: tuple[Utterance, ...]  # test-mixture targets (all from test_chapter)
    enrollment: tuple[Utterance, ...]  # enrollment stream, in order
    relations: tuple[str, ...]  # per enrollment utterance, its relation to the test chapter (RELATIONS)
    contaminated_positions: tuple[int, ...]  # indices into `enrollment`
    flags: tuple[str, ...]  # e.g. "single-chapter", "targets-relaxed-2-30s", "enroll-short:28"

    def relation_at(self, k: int) -> str:
        """The weakest separation among the first k enrollment dictations:
        cross_project only if every one of them is from another LibriVox project."""
        rel = self.relations[:k]
        return max(rel, key=RELATIONS.index) if rel else RELATIONS[0]


def _pad_to_frames(x: np.ndarray) -> np.ndarray:
    r = (-x.size) % FRAME_SAMPLES
    return np.pad(x, (0, r)) if r else x


@lru_cache(maxsize=256)
def _utt_audio(path: str) -> np.ndarray:
    """Dry utterance padded to whole frames (read-only)."""
    x = _pad_to_frames(load_audio(path))
    x.setflags(write=False)
    return x


def _place_audio(x: np.ndarray, offset_frames: int, total_frames: int) -> np.ndarray:
    out = np.zeros(total_frames * FRAME_SAMPLES, dtype=np.float32)
    s = max(0, offset_frames) * FRAME_SAMPLES
    e = min(total_frames * FRAME_SAMPLES, offset_frames * FRAME_SAMPLES + x.size)
    if e > s:
        out[s:e] = x[s - offset_frames * FRAME_SAMPLES : e - offset_frames * FRAME_SAMPLES]
    return out


def _segment(rng: np.random.Generator, entry: dict[str, Any], n: int) -> tuple[np.ndarray, int]:
    """n samples from a noise/music entry's split range, tiled if it is shorter."""
    lo, hi = int(entry["start"]), int(entry["end"])
    length = hi - lo
    if length >= n:
        start = lo + int(rng.integers(0, length - n + 1))
        x = load_audio(entry["path"], start=start, frames=n, channel=int(entry.get("channel", 0)))
    else:
        start = lo
        x = load_audio(entry["path"], start=lo, frames=length, channel=int(entry.get("channel", 0)))
        x = np.tile(x, int(np.ceil(n / max(1, x.size))))[:n]
    if x.size < n:
        x = np.pad(x, (0, n - x.size))
    return x.astype(np.float32), start


def _level(x: np.ndarray, act: np.ndarray, target_db: float) -> tuple[np.ndarray, float]:
    g = 10 ** ((target_db - active_level_db(x, act)) / 20)
    return (x * g).astype(np.float32), float(g)


class MixtureGenerator:
    def __init__(self, split: str, corpus: Corpus | None = None, speakers: Sequence[str] | None = None, pin_sources: bool = False,
                 label_gap_s: float = GAP_S):
        """`speakers` restricts every speaker role drawn at random (targets,
        interferers, TV programmes, contamination) to a subset of the split, e.g.
        a dev half (lfspk.harness.halves), so mixtures never cross halves."""
        self.split = split
        self.corpus = corpus or Corpus(split)
        pool = list(self.corpus.speakers) if speakers is None else [str(x) for x in speakers]
        unknown = set(pool) - set(self.corpus.speakers)
        if unknown or len(pool) < 3:
            raise ValueError(f"bad speaker pool: unknown {sorted(unknown)[:5]}, size {len(pool)}")
        self.pool = sorted(pool, key=int)
        self.pin_sources = pin_sources
        # Label rule variant: GAP_S (primary) or NO_MERGE_GAP_S (sensitivity). Audio never depends on it.
        self.label_gap_s = float(label_gap_s)
        self._used: set[str] | None = None
        self._far_cache: dict[tuple[float, float, bool], list[dict[str, Any]]] = {}

    # --- speaker plans ----------------------------------------------------------

    def speaker_plan(self, speaker: str, n_targets: int = 10, n_enroll: int = 30) -> SpeakerPlan:
        rng = rng_for("plan", self.split, speaker, n_targets, n_enroll)
        utts = self.corpus.utterances[speaker]
        flags: list[str] = []
        chapters = sorted({u.chapter for u in utts}, key=int)

        def ok(u: Utterance, lo: float, hi: float) -> bool:
            return lo <= u.seconds <= hi

        def qualifying(ch: str, lo: float, hi: float) -> list[Utterance]:
            return [u for u in utts if u.chapter == ch and ok(u, lo, hi)]

        proj = self.corpus.project
        enrollable = [u for u in utts if ok(u, 2.0, 20.0)]

        def cross(ch: str) -> int:
            p = proj(next(u for u in utts if u.chapter == ch))
            return sum(1 for u in enrollable if proj(u) != p)

        def other(ch: str) -> int:
            return sum(1 for u in enrollable if u.chapter != ch)

        lo, hi = TARGET_SECONDS
        full = [c for c in chapters if len(qualifying(c, lo, hi)) >= n_targets]
        if not full:
            lo, hi = 2.0, 30.0
            flags.append("targets-relaxed-2-30s")
            full = [c for c in chapters if len(qualifying(c, lo, hi)) >= n_targets]
        if full:
            # Prefer a test chapter leaving a full enrollment stream from other
            # LibriVox projects (other recording setups); else a full stream from
            # other chapters with the most cross-project audio; else the most
            # other-chapter audio.
            tier = [c for c in full if cross(c) >= n_enroll]
            if not tier:
                enough = [c for c in full if other(c) >= n_enroll]
                if enough:
                    best = max(cross(c) for c in enough)
                    tier = [c for c in enough if cross(c) == best]
                else:
                    best = max(other(c) for c in full)
                    tier = [c for c in full if other(c) == best]
            test_chapter = tier[int(rng.integers(len(tier)))]
        else:
            test_chapter = max(chapters, key=lambda c: (len(qualifying(c, lo, hi)), -int(c)))
            flags.append("targets-short")
        test_project = proj(next(u for u in utts if u.chapter == test_chapter))
        pool = qualifying(test_chapter, lo, hi)
        pick = rng.permutation(len(pool))[:n_targets]
        targets = sorted((pool[i] for i in pick), key=lambda u: u.id)
        target_ids = {u.id for u in targets}
        if len(chapters) == 1:
            flags.append("single-chapter")
        if len({proj(u) for u in utts}) == 1:
            flags.append("single-project")
        groups: dict[str, list[Utterance]] = {r: [] for r in RELATIONS}
        for u in enrollable:
            if u.id in target_ids:
                continue
            rel = "same_chapter" if u.chapter == test_chapter else "same_project_cross_chapter" if proj(u) == test_project else "cross_project"
            groups[rel].append(u)
        if len(chapters) > 1:
            groups["same_chapter"] = []  # the contract falls back no further than another chapter
        enroll: list[Utterance] = []
        relations: list[str] = []
        for rel in RELATIONS:  # strongest separation first
            g = groups[rel]
            for i in rng.permutation(len(g)):
                if len(enroll) < n_enroll:
                    enroll.append(g[i])
                    relations.append(rel)
        if len(enroll) < n_enroll:
            flags.append(f"enroll-short:{len(enroll)}")
        crng = rng_for("contamination", self.split, speaker)
        positions = tuple(p for b in range(0, n_enroll, 5) if (p := b + int(crng.integers(5))) < len(enroll))
        return SpeakerPlan(speaker, test_chapter, test_project, tuple(targets), tuple(enroll), tuple(relations), positions, tuple(flags))

    # --- RIRs ------------------------------------------------------------------------
    #
    # Primary mode "coherent": every source sits in the target's simulated room
    # (one bank room per seed): the target at its near-field role, other people
    # and the TV at far roles (distinct positions where the room has them), call
    # audio at the laptop-speaker role. Secondary mode "mixed": every source,
    # the target included, independently draws its RIR from another bank room, an
    # OpenSLR 26 room or a measured room with equal probability, so RIR
    # provenance carries no target/interferer cue.

    def _slr26(self, lo: float, hi: float, medium: bool) -> list[dict[str, Any]]:
        key = ("slr26", lo, hi, medium)
        if key not in self._far_cache:
            self._far_cache[key] = [e for e in self.corpus.aux("rir_slr26") if lo <= e["distance"] <= hi and (medium or e["room"].startswith("small"))]
        return self._far_cache[key]

    def _measured(self, near: bool) -> list[dict[str, Any]]:
        """Measured RIRs of the one family with near and far positions in the
        same rooms (REVERB 2014: 0.5 m and 2 m), so both roles share one
        measurement chain (r2 #2). BUT ReverbDB, RWCP and AIR are not used."""
        key = ("measured", near)
        if key not in self._far_cache:
            self._far_cache[key] = [e for e in self.corpus.aux("rir_real") if is_reverb_measured(e) and is_near_measured(e) == near]
        return self._far_cache[key]

    def _bank_rir(self, room: int, role: str) -> tuple[np.ndarray, dict[str, Any]]:
        self._note(str(self.corpus.bank_dir / self.split / f"room-{room:04d}.npz"))
        return self.corpus.bank_rirs(room)[role], {"pool": "bank", "room": room, "role": role, "distance": self.corpus.bank[room]["distance"][role]}

    def _file_rir(self, e: dict[str, Any], pool: str) -> tuple[np.ndarray, dict[str, Any]]:
        self._note(e["path"])
        return load_rir(e["path"]), {"pool": pool, "source": e.get("source"), "id": e["key"], "room": e["room"], "distance": e.get("distance")}

    def _far_role(self, rng: np.random.Generator, room: int, lo: float, hi: float, used: set[str]) -> str:
        dist = self.corpus.bank[room]["distance"]
        far = sorted(k for k in dist if k.startswith("far_"))
        free = [k for k in far if k not in used] or far
        inside = [k for k in free if lo <= dist[k] <= hi]
        if inside:
            return inside[int(rng.integers(len(inside)))]
        return min(free, key=lambda k: abs(dist[k] - (lo + hi) / 2))

    def _pick_rir(self, rng: np.random.Generator, kind: str, mode: str, room: int, used: set[str], device: str = "builtin",
                  lo: float = 0.0, hi: float = 0.0, medium: bool = False) -> tuple[np.ndarray, dict[str, Any]]:
        """kind: 'target' (near field, device geometry), 'laptop' (call speaker) or 'far'."""
        if mode == "coherent":
            if kind == "target":
                return self._bank_rir(room, f"target_{device}")
            if kind == "laptop":
                return self._bank_rir(room, "laptop_speaker")
            role = self._far_role(rng, room, lo, hi, used)
            used.add(role)
            return self._bank_rir(room, role)
        pool = ("bank", "slr26", "measured")[int(rng.integers(3))]
        if kind == "target" and device == "headset":
            pool = "bank"  # no other source of 2-5 cm responses
        if pool == "slr26":
            cands = self._slr26(0.0, 0.6, True) if kind != "far" else self._slr26(lo, hi, medium)
            if cands:
                return self._file_rir(cands[int(rng.integers(len(cands)))], "slr26")
        if pool == "measured":
            cands = self._measured(kind != "far")
            if cands:
                return self._file_rir(cands[int(rng.integers(len(cands)))], "measured")
        other = int(rng.integers(len(self.corpus.bank)))
        if kind == "target":
            return self._bank_rir(other, f"target_{device}")
        if kind == "laptop":
            return self._bank_rir(other, "laptop_speaker")
        return self._bank_rir(other, self._far_role(rng, other, lo, hi, set()))

    # --- speakers and utterances ---------------------------------------------------------

    def _random_target(self, rng: np.random.Generator) -> Utterance:
        spk = self.pool[int(rng.integers(len(self.pool)))]
        utts = [u for u in self.corpus.utterances[spk] if TARGET_SECONDS[0] <= u.seconds <= TARGET_SECONDS[1]] or self.corpus.utterances[spk]
        return utts[int(rng.integers(len(utts)))]

    def _other_speaker(self, rng: np.random.Generator, exclude: set[str], sex: str | None = None) -> str:
        cands = [s for s in self.pool if s not in exclude and (sex is None or self.corpus.sex[s] == sex)]
        if not cands:
            cands = [s for s in self.pool if s not in exclude]
        return cands[int(rng.integers(len(cands)))]

    def _random_utt(self, rng: np.random.Generator, speaker: str, min_seconds: float = 1.5) -> Utterance:
        utts = [u for u in self.corpus.utterances[speaker] if u.seconds >= min_seconds] or self.corpus.utterances[speaker]
        return utts[int(rng.integers(len(utts)))]

    def _utt(self, u: Utterance) -> tuple[np.ndarray, np.ndarray]:
        """Dry audio and its frame activity from the utterance's forced alignment
        (DESIGN.md section 5); an utterance without one is an error."""
        self._note(str(u.path))
        x = _utt_audio(str(u.path))
        words = self.corpus.alignment(u.id)
        if not words:
            raise RuntimeError(f"no forced alignment for {u.id}; run lfspk.harness.forced for split {self.split}")
        a = activity_from_alignment(words, x.size, gap_s=self.label_gap_s)
        a.setflags(write=False)
        return x, a

    def _segment(self, rng: np.random.Generator, entry: dict[str, Any], n: int) -> tuple[np.ndarray, int]:
        self._note(entry["path"])
        return _segment(rng, entry, n)

    def _note(self, path: str) -> None:
        if self._used is not None:
            self._used.add(path)

    # --- interferer layouts -------------------------------------------------------------

    def _segment_from(self, rng: np.random.Generator, u: Utterance, lo_s: float, hi_s: float, cut_at_pause: bool) -> tuple[np.ndarray, np.ndarray, dict[str, Any]]:
        x, a = self._utt(u)
        nf = a.size
        seg = min(nf, seconds_to_frames(rng, lo_s, hi_s))
        if cut_at_pause:
            start = 0
            end = seg
            gaps = [(s, e) for s, e in runs(~a) if s > 0 and e < nf]
            near = [(s + e) // 2 for s, e in gaps if abs((s + e) // 2 - seg) <= 100]
            if near:
                end = min(near, key=lambda c: abs(c - seg))
        else:
            start = int(rng.integers(0, nf - seg + 1))
            end = start + seg
        info = {"utt": u.id, "speaker": u.speaker, "frames": [start, end], "text": u.text if (start == 0 and end == nf) else None}
        return x[start * FRAME_SAMPLES : end * FRAME_SAMPLES], a[start:end].copy(), info

    def _s1(self, rng, F, target_speaker, pick):
        n = min(int(rng.choice([1, 2, 3], p=[0.5, 0.3, 0.2])), len(self.pool) - 1)
        out, used = [], {target_speaker}
        for _ in range(n):
            spk = self._other_speaker(rng, used)
            used.add(spk)
            for _try in range(10):
                x, a, info = self._segment_from(rng, self._random_utt(rng, spk), 1.5, 8.0, cut_at_pause=False)
                if a.sum() >= MIN_ACTIVE_FRAMES:
                    break
            nf = a.size
            off = int(rng.integers(0, max(0, F - nf) + 1)) if nf <= F else -int(rng.integers(0, nf - F + 1))
            h, rinfo = pick(rng, "far", *FAR_DISTANCE["S1"], True)
            dry = _place_audio(x, off, F)
            out.append({"kind": "office", "dry": dry, "source": dry, "act": place(a, off, F), "rir": h, "rir_info": rinfo,
                        "info": {**info, "offset": off, "placements": [[info["utt"], info["frames"][0], info["frames"][1], off]]}})
        return out

    def _speech_programme(self, rng, F, exclude):
        """TV speech: a LibriSpeech dialogue of 1-2 other speakers (utterances with
        0.2-0.8 s gaps), F frames, starting at a random point of the first
        utterance. Metadata lists only the utterances (and so speakers) audible
        in the crop. (MUSAN us-gov was dropped so every speech label comes from a
        forced alignment.)"""
        spk = [self._other_speaker(rng, exclude)]
        if rng.random() < 0.5:
            spk.append(self._other_speaker(rng, exclude | {spk[0]}))
        parts_x, parts_a, info, placements = [], [], [], []
        total, k = 0, 0
        preroll = None
        while preroll is None or total < preroll + F:
            u = self._random_utt(rng, spk[k % len(spk)])
            x, a = self._utt(u)
            if preroll is None:
                preroll = int(rng.integers(0, a.size))
            gap = seconds_to_frames(rng, 0.2, 0.8)
            parts_x += [x, np.zeros(gap * FRAME_SAMPLES, np.float32)]
            parts_a += [a, np.zeros(gap, bool)]
            lo, hi = max(0, preroll - total), min(a.size, preroll + F - total)
            if hi > lo and a[lo:hi].any():
                info.append({"utt": u.id, "speaker": u.speaker, "offset": total - preroll})
            placements.append([u.id, 0, a.size, total - preroll])
            total += a.size + gap
            k += 1
        x = np.concatenate(parts_x)[preroll * FRAME_SAMPLES : (preroll + F) * FRAME_SAMPLES]
        a = np.concatenate(parts_a)[preroll : preroll + F]
        speakers = sorted({i["speaker"] for i in info}, key=int)
        return x, a, {"programme": "librispeech", "speakers": speakers, "utts": info, "preroll": preroll, "placements": placements}

    def _s2(self, rng, F, target_speaker, pick):
        for _try in range(10):
            speech, a, info = self._speech_programme(rng, F, {target_speaker})
            if a.sum() >= MIN_ACTIVE_FRAMES:
                break
        prog = speech.copy()
        music = None
        if rng.random() < 0.5 and self.corpus.aux("music"):
            pool = self.corpus.aux("music")
            e = pool[int(rng.integers(len(pool)))]
            m, start = self._segment(rng, e, speech.size)
            smr = float(rng.uniform(5, 15))
            if np.any(m) and a.any():
                g = 10 ** ((active_level_db(speech, a) - smr - mean_level_db(m)) / 20)
                prog = prog + (m * g).astype(np.float32)
                music = {"id": e["key"], "start": start, "speech_to_music_db": smr}
        spk = channels.draw_tv_speaker(rng)
        x = channels.apply_speaker(channels.compress(prog), spk)
        h, rinfo = pick(rng, "far", *FAR_DISTANCE["S2"], False)
        return [{"kind": "tv", "dry": speech, "source": x, "act": a, "rir": h, "rir_info": rinfo, "info": {**info, "music": music, "speaker_colouring": spk}}]

    def _s4(self, rng, F, target_speaker, target_first_active, pick):
        sex = self.corpus.sex[target_speaker]
        same = rng.random() < 0.6
        other_sex = {"F": "M", "M": "F"}[sex]
        spk = self._other_speaker(rng, {target_speaker}, sex if same else other_sex)
        utts = sorted(self.corpus.utterances[spk], key=lambda u: u.id)
        i = int(rng.integers(len(utts)))
        chosen = [utts[i]]
        if rng.random() < 0.5 and i + 1 < len(utts) and utts[i + 1].chapter == utts[i].chapter:
            chosen.append(utts[i + 1])
        xs, acts, starts = [], [], []
        pos = 0
        for j, u in enumerate(chosen):
            x, a = self._utt(u)
            xs.append(x)
            acts.append(a)
            starts.append(pos)
            pos += a.size
            if j + 1 < len(chosen):
                gap = seconds_to_frames(rng, 0.3, 1.0)
                xs.append(np.zeros(gap * FRAME_SAMPLES, np.float32))
                acts.append(np.zeros(gap, bool))
                pos += gap
        x, a = np.concatenate(xs), np.concatenate(acts)
        first = int(np.flatnonzero(a)[0]) if a.any() else 0
        off = target_first_active + seconds_to_frames(rng, -2.0, 2.0) - first
        h, rinfo = pick(rng, "far", *FAR_DISTANCE["S4"], False)
        dry = _place_audio(x, off, F)
        info = {"utts": [u.id for u in chosen], "speaker": spk, "sex": self.corpus.sex[spk], "same_sex": self.corpus.sex[spk] == sex, "offset": off,
                "text": " ".join(u.text for u in chosen),
                "placements": [[u.id, 0, acts[2 * j].size, off + st] for j, (u, st) in enumerate(zip(chosen, starts))]}
        return [{"kind": "dictator", "dry": dry, "source": dry, "act": place(a, off, F), "rir": h, "rir_info": rinfo, "info": info}]

    # --- render -------------------------------------------------------------------------------

    def render(self, scenario: str, seed: int, target: Utterance | str | None = None, device: str = "builtin", rir_mode: str = "coherent") -> Mixture:
        """One mixture. Equivalent to render_paired((scenario,), ...)[scenario]."""
        return self.render_paired((scenario,), seed, target, device, rir_mode)[scenario]

    def render_paired(self, scenarios: Sequence[str], seed: int, target: Utterance | str | None = None, device: str = "builtin",
                      rir_mode: str = "coherent") -> dict[str, Mixture]:
        """Several scenarios of one seed with one shared peak-limiting gain, so the
        target and noise components of S0, S1, S2 and S4 are bit-identical (S3
        re-times the target, so only its room, levels and device are shared)."""
        for s in scenarios:
            if s not in SCENARIOS:
                raise ValueError(f"unknown scenario {s!r}")
        if device not in channels.DEVICES:
            raise ValueError(f"unknown device {device!r}")
        if rir_mode not in RIR_MODES:
            raise ValueError(f"unknown rir_mode {rir_mode!r}")
        if isinstance(target, str):
            target = self.corpus.utterance_by_id[target]
        raw = {}
        for s in scenarios:
            for attempt in range(6):
                try:
                    raw[s] = self._render(s, seed, target, device, rir_mode, attempt)
                    break
                except _Retry:
                    continue
            else:
                raise RuntimeError(f"could not render {s} seed {seed}")
        peak = max(float(np.max(np.abs(m.audio))) if m.audio.size else 0.0 for m in raw.values())
        g = np.float32(PEAK_LIMIT / peak) if peak > PEAK_LIMIT else np.float32(1.0)
        for m in raw.values():
            if g != 1.0:
                m.target, m.target_dry, m.noise = m.target * g, m.target_dry * g, m.noise * g
                m.interferers = [x * g for x in m.interferers]
                m.interferers_dry = [x * g for x in m.interferers_dry]
                m.noise_parts = {k: x * g for k, x in m.noise_parts.items()}
                m.audio = m.target + m.noise
                for x in m.interferers:
                    m.audio = m.audio + x
            m.audio = np.clip(m.audio, -1.0, 1.0).astype(np.float32)
            m.meta["peak_gain_db"] = float(20 * np.log10(float(g)))
            m.meta["paired_with"] = list(scenarios)
            m.meta["target"]["level_measured_dbfs"] = active_level_db(m.target, m.target_active)
        return raw

    def render_noise_group(self, seed: int, target: Utterance | str, specs: Sequence[dict[str, Any]], device: str = "builtin",
                           max_reselect: int = 20) -> list[Mixture]:
        """Noise-only variants of the S0 render of (seed, target) (W5 DESIGN 9.4):
        each spec {"family": "noise" | "music", "snr_db": float} adds one MUSAN
        noise file or no-vocals music file to the paired S0, whose background
        (ambience, DEMAND or SLR28 isotropic, and self-noise) stays
        bit-identical; only the added source is scaled, to snr_db (active target
        image over the source image). The limiter gain is the one of the paired S0-S4 group
        (render_paired(SCENARIOS)), so the target component is bit-identical to
        that S0 (noise-r1 #1). A variant that would exceed the peak limit at that
        gain re-draws its MUSAN file deterministically (meta noise_spec
        reselections); more than max_reselect re-draws is an error."""
        if isinstance(target, str):
            target = self.corpus.utterance_by_id[target]
        ref = self.render_paired(SCENARIOS, seed, target, device)["S0"]
        g = np.float32(10 ** (ref.meta["peak_gain_db"] / 20))
        # Re-draws are per family: all SNRs of a family share one MUSAN file, so
        # the SNR comparison is never confounded with a change of source.
        families = list(dict.fromkeys(sp["family"] for sp in specs))
        chosen: dict[tuple[str, float], tuple[Mixture, int, list[float]]] = {}
        for fam in families:
            fam_specs = [sp for sp in specs if sp["family"] == fam]
            for k in range(max_reselect + 1):
                ms = [_apply_gain(self._render("S0", seed, target, device, "coherent", 0, noise_spec={**sp, "reselect": k}), g) for sp in fam_specs]
                # The checked array is the one written (noise-r3: no separate rounding path).
                over = [float(sp["snr_db"]) for sp, m in zip(fam_specs, ms) if float(np.max(np.abs(m.audio))) > PEAK_LIMIT]
                if not over:
                    break
                trig = over if k == 0 else trig  # the SNRs that forced the first re-draw
            else:
                raise RuntimeError(f"noise family {fam} of seed {seed} clips after {max_reselect} re-draws")
            for sp, m in zip(fam_specs, ms):
                chosen[(fam, float(sp["snr_db"]))] = (m, k, trig if k else [])
        out = []
        for sp in specs:
            m, k, trig = chosen[(sp["family"], float(sp["snr_db"]))]  # already gained; audio is the checked array
            m.meta["peak_gain_db"] = ref.meta["peak_gain_db"]
            m.meta["paired_with"] = ["S0 of " + ",".join(SCENARIOS)]
            m.meta["noise_spec"] = {**sp, "reselections": k, "reselect_triggered_by_snr": trig,
                                    "snr_measured_db": active_level_db(m.target, m.target_active) - mean_level_db(m.noise_parts["event"]),
                                    "inherited_ambience_snr_db": m.meta["ambience"]["snr_db"]}
            m.meta["target"]["level_measured_dbfs"] = active_level_db(m.target, m.target_active)
            out.append(m)
        return out

    def _render(self, scenario: str, seed: int, target: Utterance | None, device: str, rir_mode: str, attempt: int,
                noise_spec: dict[str, Any] | None = None) -> Mixture:
        """Components before peak limiting. The base stream (target, placement,
        room, level, ambience, SNR quantile) ignores scenario and attempt; only
        the scenario stream is re-drawn on a retry."""
        self._used = set() if self.pin_sources else None
        base = rng_for("mix-base", self.split, seed)
        scn = rng_for("mix-scenario", self.split, scenario, seed, attempt)
        rir_rng = rng_for("mix-rir", self.split, seed)
        if target is None:
            target = self._random_target(base)
        x_t, a_t = self._utt(target)
        if not a_t.any():
            raise RuntimeError(f"target {target.id} has no active frames")
        lead = seconds_to_frames(base, *LEAD_SECONDS)
        tail = seconds_to_frames(base, *LEAD_SECONDS)
        room = int(base.integers(len(self.corpus.bank)))
        level_t = float(base.uniform(*TARGET_LEVEL_DBFS))
        snr_u = float(base.random())
        amb_pool = self.corpus.aux("ambience")
        amb_entry = amb_pool[int(base.integers(len(amb_pool)))]
        noise_rng = rng_for("mix-noise", self.split, seed)
        dev = channels.draw_device(self.split, target.speaker, device)
        used_roles: set[str] = set()

        def pick(rng, kind, lo=0.0, hi=0.0, medium=False):
            return self._pick_rir(rng, kind, rir_mode, room, used_roles, device, lo, hi, medium)

        # Target layout. S3 splits the target at its longest interior pause.
        target_parts: list[tuple[int, int, int]] = []  # (offset in timeline, start frame, end frame) of the utterance
        interferers: list[dict[str, Any]] = []
        nf_t = a_t.size
        if scenario == "S3":
            pauses = [(s, e) for s, e in runs(~a_t) if s > 0 and e < nf_t]
            longest = max(pauses, key=lambda p: (p[1] - p[0], -p[0]), default=None)
            cuts = [(0, nf_t)]
            if longest is not None and longest[1] - longest[0] >= 15:
                mid = (longest[0] + longest[1]) // 2
                cuts = [(0, mid), (mid, nf_t)]
            pre = scn.random() < (0.3 if len(cuts) == 2 else 1.0)
            spk = self._other_speaker(scn, {target.speaker})
            channel = channels.draw_call_channel(scn)
            spk_col = channels.draw_laptop_speaker(scn)
            items: list[tuple[str, Any]] = []
            if pre:
                items.append(("I", None))
            for j, c in enumerate(cuts):
                items.append(("T", c))
                if j + 1 < len(cuts):
                    items.append(("I", None))
            cursor_end = None  # timeline frame after the previous item's last active frame
            target_end = 0
            turns = []
            for kind, c in items:
                if kind == "T":
                    s, e = c
                    seg_a = a_t[s:e]
                    first = int(np.flatnonzero(seg_a)[0]) if seg_a.any() else 0
                    last = int(np.flatnonzero(seg_a)[-1]) + 1 if seg_a.any() else e - s
                    off = lead if cursor_end is None else max(0, cursor_end + seconds_to_frames(scn, -0.5, 1.0) - first)
                    if target_parts:  # the target never overlaps itself
                        po, ps, pe = target_parts[-1]
                        off = max(off, target_end + 10 - first, po + (pe - ps) - first)
                    target_parts.append((off, s, e))
                    cursor_end = target_end = off + last
                else:
                    for _try in range(10):
                        xi, ai, info = self._segment_from(scn, self._random_utt(scn, spk), 1.5, 6.0, cut_at_pause=True)
                        if ai.sum() >= MIN_ACTIVE_FRAMES:
                            break
                    first = int(np.flatnonzero(ai)[0]) if ai.any() else 0
                    last = int(np.flatnonzero(ai)[-1]) + 1 if ai.any() else ai.size
                    off = lead if cursor_end is None else max(0, cursor_end + seconds_to_frames(scn, -0.5, 1.0) - first)
                    turns.append({"x": xi, "a": ai, "off": off, "info": {**info, "offset": off}})
                    cursor_end = off + last
            F = max(o + (e - s) for o, s, e in target_parts) + tail
            if turns:
                # One far-end talker: the call channel and the laptop speaker process the whole far-end track.
                dry = np.sum([_place_audio(t["x"], t["off"], F) for t in turns], axis=0).astype(np.float32)
                act = np.any([place(t["a"], t["off"], F) for t in turns], axis=0)
                src = channels.apply_speaker(channels.apply_call_channel(dry, channel), spk_col)
                h, rinfo = pick(scn, "laptop")
                interferers = [{"kind": "call", "dry": dry, "source": src, "act": act, "rir": h, "rir_info": rinfo,
                                "info": {"speaker": spk, "turns": [t["info"] for t in turns], "call_channel": channel, "speaker_colouring": spk_col,
                                         "placements": [[t["info"]["utt"], t["info"]["frames"][0], t["info"]["frames"][1], t["off"]] for t in turns]}}]
        else:
            target_parts = [(lead, 0, nf_t)]
            F = lead + nf_t + tail

        target_dry = np.zeros(F * FRAME_SAMPLES, np.float32)
        target_act = np.zeros(F, bool)
        for off, s, e in target_parts:
            target_dry += _place_audio(x_t[s * FRAME_SAMPLES : e * FRAME_SAMPLES], off, F)
            target_act |= place(a_t[s:e], off, F)
        first_active = int(np.flatnonzero(target_act)[0])

        if scenario == "S1":
            interferers = self._s1(scn, F, target.speaker, pick)
        elif scenario == "S2":
            interferers = self._s2(scn, F, target.speaker, pick)
        elif scenario == "S4":
            interferers = self._s4(scn, F, target.speaker, first_active, pick)
        interferers = [it for it in interferers if it["act"].sum() >= MIN_ACTIVE_FRAMES]
        if scenario != "S0" and not interferers:
            raise _Retry

        N = F * FRAME_SAMPLES
        h_t, t_rinfo = self._pick_rir(rir_rng, "target", rir_mode, room, set(), device)
        target_img = channels.apply_device(convolve(target_dry, h_t, N), dev, near_source=True)
        target_img, g_t = _level(target_img, target_act, level_t)
        target_dry = (target_dry * g_t).astype(np.float32)

        imgs, dries, acts, ints_meta = [], [], [], []
        for it in interferers:
            img = channels.apply_device(convolve(it["source"], it["rir"], N), dev)
            sir = float(scn.uniform(*SIR_RANGE[scenario]))
            img, g = _level(img, it["act"], level_t - sir)
            imgs.append(img)
            dries.append((it["dry"] * g).astype(np.float32))
            acts.append(it["act"])
            ints_meta.append({"kind": it["kind"], "sir_db": sir, "rir": it["rir_info"], **it["info"]})

        # Acoustic noise = ambience (+ an S1 noise event, 0-10 dB above the ambience
        # over its span), scaled jointly to the scenario SNR; device self-noise is
        # added at its own absolute level and reported in the total SNR.
        lo, hi = SNR_RANGE[scenario]
        snr = lo + snr_u * (hi - lo)
        amb, amb_start = self._segment(noise_rng, amb_entry, N)
        amb = channels.apply_device(amb, dev)
        if not np.any(amb):
            amb = pink_noise(noise_rng, N)
        amb = (amb / np.sqrt(np.mean(amb.astype(np.float64) ** 2))).astype(np.float32)
        acoustic = amb.copy()
        event_meta = None
        if scenario == "S1" and scn.random() < 0.5 and self.corpus.aux("events"):
            pool = self.corpus.aux("events")
            e = pool[int(scn.integers(len(pool)))]
            nfe = min(F, seconds_to_frames(scn, 1.0, 5.0))
            ev, ev_start = self._segment(scn, e, nfe * FRAME_SAMPLES)
            if np.any(ev):
                off = int(scn.integers(0, F - nfe + 1))
                h, rinfo = pick(scn, "far", *FAR_DISTANCE["event"], True)
                ev_img = channels.apply_device(convolve(_place_audio(ev, off, F), h, N), dev)
                span = np.zeros(F, bool)
                span[off : off + nfe] = True
                over = float(scn.uniform(0, 10))
                if np.any(ev_img[off * FRAME_SAMPLES : (off + nfe) * FRAME_SAMPLES]):
                    # Relative to the ambience over the event's own span (r2 #3).
                    ev_img, _ = _level(ev_img, span, active_level_db(amb, span) + over)
                    acoustic = acoustic + ev_img
                    event_meta = {"id": e["key"], "start": ev_start, "offset": off, "frames": nfe, "event_over_ambience_db": over, "rir": rinfo}
        g_ac = 10 ** ((level_t - snr - mean_level_db(acoustic)) / 20)
        event_part = ((acoustic - amb) * g_ac).astype(np.float32)
        amb_part = (amb * g_ac).astype(np.float32)
        acoustic = (acoustic * g_ac).astype(np.float32)
        self_noise_db = dev["self_noise_dbfs"]
        self_part = (pink_noise(noise_rng, N) * 10 ** (self_noise_db / 20)).astype(np.float32)
        noise = acoustic + self_part
        if noise_spec is not None:
            # Noise-only variant (W5 DESIGN 9.4; noise-r2 #1): the paired S0's
            # background (ambience and self-noise) is kept bit-identical; only the
            # added MUSAN source is scaled, so that the active target image over
            # the source image (after its RIR and the device colouring, the same
            # reference as the target image; self-noise excluded) is snr_db. One
            # MUSAN file per family across its SNRs (the SNR is not in the seed).
            fam = noise_spec["family"]
            frng = rng_for("mix-noise-family", self.split, seed, fam, int(noise_spec.get("reselect", 0)))
            pool = self.corpus.aux("events" if fam == "noise" else "music")
            e = pool[int(frng.integers(len(pool)))]
            src, src_start = self._segment(frng, e, N)
            if fam == "music":
                src = channels.apply_speaker(src, channels.draw_tv_speaker(frng))
            h, rinfo = pick(frng, "far", *FAR_DISTANCE["S2"], True)
            img = channels.apply_device(convolve(src, h, N), dev)
            if not np.any(img):
                raise RuntimeError(f"silent MUSAN source {e['key']}")
            img = (img * 10 ** ((level_t - float(noise_spec["snr_db"]) - mean_level_db(img)) / 20)).astype(np.float32)
            event_part = img
            noise = noise + img
            event_meta = {"family": fam, "id": e["key"], "start": src_start, "rir": rinfo, "snr_db": float(noise_spec["snr_db"])}

        audio = target_img + noise
        for img in imgs:
            audio = audio + img

        int_act = np.any(acts, axis=0) if acts else np.zeros(F, bool)
        labels = compose_labels(target_act, int_act)
        meas_t = active_level_db(target_img, target_act)
        for m, img, a in zip(ints_meta, imgs, acts):
            m["sir_measured_db"] = meas_t - active_level_db(img, a)
        frac = np.bincount(labels, minlength=4) / max(1, F)
        meta = {
            "split": self.split, "scenario": scenario if noise_spec is None else "N",
            **({"noise_spec": noise_spec} if noise_spec is not None else {}),
            "seed": int(seed), "attempt": attempt, "device": device, "rir_mode": rir_mode,
            "device_params": dev, "frames": F, "samples": N,
            "target": {"utt": target.id, "speaker": target.speaker, "chapter": target.chapter, "sex": self.corpus.sex[target.speaker],
                       "text": target.text, "parts": [list(p) for p in target_parts], "level_dbfs": level_t, "rir": t_rinfo,
                       "placements": [[target.id, ps, pe, po] for po, ps, pe in target_parts]},
            "room": {"bank_index": room, "t60": self.corpus.bank[room]["t60"], "dims": self.corpus.bank[room]["dims"]},
            "interferers": ints_meta,
            "ambience": {"source": amb_entry["source"], "key": amb_entry["key"], "start": amb_start, "snr_db": snr,
                         "snr_measured_db": meas_t - mean_level_db(acoustic), "snr_total_db": meas_t - mean_level_db(noise)},
            "event": event_meta, "self_noise_dbfs": self_noise_db,
            "label_fractions": [float(v) for v in frac],
            "overlap_of_target": float(np.sum(labels == 3) / max(1, target_act.sum())),
            "index_hashes": self.corpus.index_hashes(),
        }
        if self._used is not None:
            meta["sources"] = {p: _source_hash(p) for p in sorted(self._used)}
        self._used = None
        return Mixture(audio.astype(np.float32), target_img.astype(np.float32), target_dry.astype(np.float32), [i.astype(np.float32) for i in imgs],
                       [d.astype(np.float32) for d in dries], noise.astype(np.float32), labels, target_act, int_act, acts, meta,
                       {"ambience": amb_part, "event": event_part, "self": self_part})

    # --- enrollment ------------------------------------------------------------------------------

    def enrollment_dictation(self, utt: Utterance | str, seed: int, device: str = "builtin", contaminated: bool = False) -> Mixture:
        """One enrollment dictation: rendered like S0, or like S4 when contaminated."""
        m = self.render("S4" if contaminated else "S0", seed, target=utt, device=device)
        m.meta["enrollment"] = {"contaminated": contaminated}
        return m

    def enrollment_streams(self, plan: SpeakerPlan, set_seed: int, device: str, contaminator: "MixtureGenerator | None" = None) -> tuple[list[Mixture], list[Mixture]]:
        """The clean and the contaminated enrollment stream of a plan (DESIGN.md
        section 6). They share every dictation except at contaminated positions,
        where the twins are rendered together (one shared limiter gain) and differ
        only by the added S4-like talker. `contaminator` draws that talker from
        another speaker pool (dev: the other half)."""
        gen = contaminator or self
        clean, dirty = [], []
        for j, u in enumerate(plan.enrollment):
            seed = stable_int("enroll", self.split, set_seed, plan.speaker, j) % (2**63)
            if j in plan.contaminated_positions:
                pair = gen.render_paired(("S0", "S4"), seed, target=u, device=device)
                c, d = pair["S0"], pair["S4"]
            else:
                c = d = self.render("S0", seed, target=u, device=device)
            for m, flag in ((c, False), (d, j in plan.contaminated_positions)):
                m.meta["enrollment"] = {"contaminated": flag, "relation": plan.relations[j], "index": j}
            clean.append(c)
            dirty.append(d)
        return clean, dirty

    def enrollment(self, plan: SpeakerPlan, set_seed: int, device: str, contaminated: bool, contaminator: "MixtureGenerator | None" = None) -> list[Mixture]:
        clean, dirty = self.enrollment_streams(plan, set_seed, device, contaminator)
        return dirty if contaminated else clean


def _apply_gain(m: Mixture, g: np.float32) -> Mixture:
    """Scale every component by the shared limiter gain and form the audio once
    (as render_paired does), so the peak check and the written audio agree."""
    if g != 1.0:
        m.target, m.target_dry, m.noise = m.target * g, m.target_dry * g, m.noise * g
        m.noise_parts = {k: x * g for k, x in m.noise_parts.items()}
        m.audio = m.target + m.noise
    m.audio = m.audio.astype(np.float32)
    return m


def placed_activity(corpus: Corpus, placements: Sequence[Sequence[Any]], n_frames: int, gap_s: float) -> np.ndarray:
    """Activity of a placed source under a label rule: OR over its placements
    [utt_id, start_frame, end_frame, offset_frame] of the utterance's alignment
    activity, sliced and shifted into the timeline."""
    out = np.zeros(n_frames, bool)
    for uid, s, e, off in placements:
        u = corpus.utterance_by_id[uid]
        words = corpus.alignment(uid)
        if not words:
            raise RuntimeError(f"no forced alignment for {uid}")
        n = -(-u.samples // FRAME_SAMPLES)  # padded to whole frames, as rendered
        a = activity_from_alignment(words, n * FRAME_SAMPLES, gap_s=gap_s)
        out |= place(a[s:e], off, n_frames)
    return out


def relabel(corpus: Corpus, meta: dict[str, Any], gap_s: float) -> tuple[np.ndarray, np.ndarray, list[np.ndarray]]:
    """(labels, target_active, interferer_actives) of a rendered mixture under
    another label rule, from the placements recorded in its meta. With the
    primary rule this reproduces the rendered labels exactly (tested)."""
    F = int(meta["frames"])
    t = placed_activity(corpus, meta["target"]["placements"], F, gap_s)
    ints = [placed_activity(corpus, it["placements"], F, gap_s) for it in meta["interferers"]]
    i = np.any(ints, axis=0) if ints else np.zeros(F, bool)
    return compose_labels(t, i), t, ints


@lru_cache(maxsize=None)
def _source_hash(path: str) -> str:
    return sha256_file(Path(path))


def is_reverb_measured(e: dict[str, Any]) -> bool:
    """REVERB 2014 measured RIRs (SLR28 real set)."""
    return e.get("source") == "slr28-real" and e["key"].startswith("RVB2014_")


def is_near_measured(e: dict[str, Any]) -> bool:
    """REVERB 2014 'near' positions (0.5 m); 'far' positions are 2 m."""
    return is_reverb_measured(e) and "_near_" in e["key"]


class _Retry(Exception):
    pass


class MixtureSampler:
    """An unbounded, indexable training stream: `sampler[i]` is a pure function of
    (split, base_seed, i). Scenario weights default to uniform over S0-S4;
    `p_headset` renders that fraction with the headset colouring and
    `p_mixed_rir` that fraction with the secondary (mixed) RIR mode."""

    def __init__(self, split: str, base_seed: int = 0, scenarios: Sequence[str] = SCENARIOS, weights: Sequence[float] | None = None,
                 p_headset: float = 0.0, corpus: Corpus | None = None, speakers: Sequence[str] | None = None, p_mixed_rir: float = 0.0):
        self.gen = MixtureGenerator(split, corpus, speakers)
        self.p_mixed_rir = float(p_mixed_rir)
        self.split = split
        self.base_seed = int(base_seed)
        self.scenarios = tuple(scenarios)
        w = np.ones(len(self.scenarios)) if weights is None else np.asarray(weights, dtype=float)
        self.weights = w / w.sum()
        self.p_headset = float(p_headset)

    def _draw(self, i: int) -> tuple[str, int, str, str]:
        rng = rng_for("sampler", self.split, self.base_seed, int(i))
        scenario = self.scenarios[int(rng.choice(len(self.scenarios), p=self.weights))]
        seed = int(rng.integers(2**62))
        device = "headset" if rng.random() < self.p_headset else "builtin"
        mode = "mixed" if rng.random() < self.p_mixed_rir else "coherent"
        return scenario, seed, device, mode

    def __getitem__(self, i: int) -> Mixture:
        scenario, seed, device, mode = self._draw(i)
        return self.gen.render(scenario, seed, device=device, rir_mode=mode)

    def with_enrollment(self, i: int, n: int, contamination: float = 0.0, device: str | None = None) -> tuple[Mixture, list[Mixture]]:
        """Mixture i plus n enrollment dictations of its target speaker, none of
        them the target utterance: other LibriVox projects first, then other
        chapters of the same project, then the same chapter only for
        single-chapter speakers (each dictation's
        meta["enrollment"]["relation"] says which). Each dictation is
        contaminated with probability `contamination`."""
        m = self[i]
        corpus = self.gen.corpus
        spk, utt_id = m.meta["target"]["speaker"], m.meta["target"]["utt"]
        tgt = corpus.utterance_by_id[utt_id]
        rng = rng_for("sampler-enroll", self.split, self.base_seed, int(i))
        utts = [u for u in corpus.utterances[spk] if u.id != utt_id and 2.0 <= u.seconds <= 20.0]

        def rel(u: Utterance) -> str:
            if u.chapter == tgt.chapter:
                return "same_chapter"
            return "same_project_cross_chapter" if corpus.project(u) == corpus.project(tgt) else "cross_project"

        single_chapter = len({u.chapter for u in corpus.utterances[spk]}) == 1
        ordered: list[Utterance] = []
        for r in RELATIONS:
            if r == "same_chapter" and not single_chapter:
                continue
            g = [u for u in utts if rel(u) == r]
            ordered += [g[k] for k in rng.permutation(len(g))]
        dev = device or m.meta["device"]
        out = []
        for u in ordered[:n]:
            d = self.gen.enrollment_dictation(u, int(rng.integers(2**62)), dev, bool(rng.random() < contamination))
            d.meta["enrollment"]["relation"] = rel(u)
            out.append(d)
        return m, out
