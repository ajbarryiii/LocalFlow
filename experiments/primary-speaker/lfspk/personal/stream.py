"""The personal tuning stream (DESIGN 2.4): a registered additive augmentation.

Example k of subject s (seed 0) is a pure function of (s, k), the subject's 10
fixed dictation recordings, the float16 public bank and p0. Placement per
family: S1/S2/S4 align the donor's target onset with the dictation's; S3
shifts the call within +-2 s of that alignment to minimise overlap with the
dictation's speech (turn-taking approximation); N needs no alignment. Levels
are measured AFTER placement: the speech interference I' (never the event
noise) is scaled so that the dictation's active target power over I''s
active power equals the donor's measured SIR_D; S1's event part E' then gets
the same gain, added separately. Absent examples are W5's T2 absent case on
the donor's own mixture. Batches are built with W5's own
`lfspk.extract.data.prepare_batch` on `Example` objects.

S3 (DESIGN amendment A1, 2026-10-24): the overlap-minimising shift
Delta = Delta0 + j, j in [-200, 200], is taken among shifts that keep at least
max(50, ceil(0.9 c0)) placed interferer-active frames, where c0 is the count
at the onset-aligned Delta0; ties go to the smaller |Delta|, then the smaller
Delta; no eligible shift rejects the donor.
"""

from __future__ import annotations

import json
from dataclasses import dataclass, field
from pathlib import Path

import numpy as np

from lfspk.api import FRAME_SAMPLES, frame_count

from .signals import MIN_ACTIVE_FRAMES, db, first_active, pact, shift_frames, shift_samples

FAMILIES = ("S0", "N", "S1", "S2", "S3", "S4")
FAMILY_WEIGHTS = (0.2, 0.1, 0.175, 0.175, 0.175, 0.175)
P_ABSENT = 0.05
N_GAIN_DB = (0.0, 15.0)
PEAK = 0.95
MAX_CANDIDATES = 20
S3_SEARCH_FRAMES = 200  # +-2 s on the 10 ms grid
S3_RETAIN = 0.9
TAGS = {"family": 0, "absent": 1, "dict": 2, "donor": 3, "gain": 4}


def rngs(seed: int, subject: str, k: int) -> dict[str, np.random.Generator]:
    """default_rng([seed, int(s), k, tag]) per stream (DESIGN 2.4; tags registered in amendment A1)."""
    return {n: np.random.default_rng([int(seed), int(subject), int(k), t]) for n, t in TAGS.items()}


@dataclass
class Donor:
    family: str
    index: int
    target: np.ndarray
    interf: np.ndarray
    noise: np.ndarray
    event: np.ndarray
    target_active: np.ndarray
    interferer_active: np.ndarray
    sir_db: float | None
    ntr: float | None
    info: dict = field(default_factory=dict)


class Bank:
    """The packed float16 bank (render.pack), memory-mapped. `get` returns float32 copies of one donor.

    verify_current=True (nixos) also checks the pack against the current bank render identity;
    the Mac passes the pinned sha256 of pack.json instead (DESIGN 7)."""

    def __init__(self, root: Path, verify_current: bool = True, pack_sha256: str | None = None, check_files: bool = True):
        from lfspk.extract.harness_frontend import file_sha256

        if not verify_current and pack_sha256 is None:
            raise ValueError("without current-identity verification the pack's sha256 must be pinned")
        root = Path(root)
        raw = (root / "pack.json").read_bytes()
        import hashlib

        self.pack_sha256 = hashlib.sha256(raw).hexdigest()
        if pack_sha256 is not None and pack_sha256 != self.pack_sha256:
            raise RuntimeError("pack.json differs from the pinned sha256")
        meta = json.loads(raw)
        if check_files:
            for f, h in meta["files"].items():
                if file_sha256(root / f) != h:
                    raise RuntimeError(f"{f} differs from pack.json")
        if verify_current:
            from .render import validated_manifest
            from .signals import json_sha256

            man = validated_manifest("bank", check_digests=False)
            if json_sha256(man) != meta["render_manifest_sha256"] or man["identity_sha256"] != meta["render_identity_sha256"]:
                raise RuntimeError("the pack does not belong to the current bank render")
        self.meta = meta
        self.audio = np.load(root / "bank16.npy", mmap_mode="r")
        self.frames = np.load(root / "frames.npy", mmap_mode="r")
        self.index = {(e["info"]["family"], int(e["info"]["index"])): e for e in json.loads((root / "index.json").read_text())}
        self.counts = {f: sum(1 for (g, _) in self.index if g == f) for f in ("S0", "S1", "S2", "S3", "S4")}

    def get(self, family: str, i: int) -> Donor:
        e = self.index[(family, int(i))]
        a = np.asarray(self.audio[e["off"]: e["off"] + e["n"]], dtype=np.float32)
        fr = np.asarray(self.frames[e["foff"]: e["foff"] + e["nf"]])
        inf = e["info"]
        return Donor(family, int(i), a[:, 0].copy(), a[:, 1].copy(), a[:, 2].copy(), a[:, 3].copy(), fr[:, 0].copy(),
                     fr[:, 1].copy(), inf["sir_db"], inf["ntr"], inf)


@dataclass
class Dictation:
    audio: np.ndarray  # the recording d (target image + its own noise)
    target: np.ndarray  # target image (used only to place and level interference)
    target_active: np.ndarray

    def __post_init__(self):
        if frame_count(len(self.audio)) != len(self.target_active):
            raise ValueError("dictation activity length mismatch")
        if int(np.sum(self.target_active)) < MIN_ACTIVE_FRAMES:
            raise ValueError("dictation has fewer than 50 target-active frames")


@dataclass
class Placed:
    """One tuning example with its components (for the audit) and its record."""
    mix: np.ndarray
    y: np.ndarray
    labels: np.ndarray
    record: dict
    d_target: np.ndarray | None = None
    d_active: np.ndarray | None = None
    interf: np.ndarray | None = None  # the scaled placed speech interference g_I I'
    interf_active: np.ndarray | None = None


class Rejected(Exception):
    pass


def s3_shift(a_d: np.ndarray, ia: np.ndarray, f0: int, nf: int) -> tuple[int, int, int, int]:
    """(frame shift Delta, overlap, kept active frames, baseline c0) of the S3 search (amendment A1);
    raises Rejected if no shift keeps max(50, ceil(0.9 c0)) placed interferer-active frames."""
    base = int(shift_frames(ia, f0, nf).sum())
    need = max(MIN_ACTIVE_FRAMES, int(np.ceil(S3_RETAIN * base)))
    best = None
    for j in range(-S3_SEARCH_FRAMES, S3_SEARCH_FRAMES + 1):
        delta = f0 + j
        placed = shift_frames(ia, delta, nf)
        kept = int(placed.sum())
        if kept < need:
            continue
        ov = int(np.sum(placed & a_d))
        key = (ov, abs(delta), delta)
        if best is None or key < best[0]:
            best = (key, delta, ov, kept)
    if best is None:
        raise Rejected("no S3 shift keeps enough interference")
    return best[1], best[2], best[3], base


def place_present(fam: str, d: Dictation, D: Donor, gain_rng: np.random.Generator) -> Placed:
    """S1-S4 and N present cases (DESIGN 2.4 table). Raises Rejected for empty activity."""
    n, nf = len(d.audio), len(d.target_active)
    a_d = np.asarray(d.target_active, bool)
    pt = pact(d.target, a_d)
    rec = {"family": fam, "absent": False, "donor": [D.family, D.index]}
    if fam == "N":
        noise = shift_samples(D.noise, 0, n)  # cut or zero-padded to the dictation's length
        pn = float(np.mean(noise.astype(np.float64) ** 2))  # power over the whole placed window (DESIGN 2.4)
        if pn <= 0 or not D.ntr:
            raise Rejected("silent donor noise")
        gdb = float(gain_rng.uniform(*N_GAIN_DB))
        g = np.float32(np.sqrt(D.ntr * pt / pn) * 10.0 ** (gdb / 20.0))
        mix = d.audio + g * noise
        rec.update(shift_frames=0, g=float(g), n_gain_db=gdb)
        return Placed(mix.astype(np.float32), mix.astype(np.float32), np.zeros(frame_count(n), bool), rec)
    f0 = first_active(a_d) - first_active(D.target_active)
    s3 = {}
    if fam == "S3":
        fs, _, _, c0 = s3_shift(a_d, D.interferer_active, f0, nf)
        s3 = {"s3_baseline_frames": c0}
    else:
        fs = f0
    ia = shift_frames(D.interferer_active, fs, nf)
    if int(ia.sum()) < MIN_ACTIVE_FRAMES:
        raise Rejected("fewer than 50 placed interferer-active frames")
    ip = shift_samples(D.interf, fs * FRAME_SAMPLES, n)
    pi = pact(ip, ia)
    if pi <= 0 or D.sir_db is None:
        raise Rejected("silent placed interference")
    g = np.float32(np.sqrt(pt / (pi * 10.0 ** (D.sir_db / 10.0))))
    gi = g * ip
    mix = d.audio + gi
    y = d.audio
    if fam == "S1":
        ge = g * shift_samples(D.event, fs * FRAME_SAMPLES, n)
        mix = mix + ge
        y = d.audio + ge
    lo, hi = max(0, fs * FRAME_SAMPLES), min(n, fs * FRAME_SAMPLES + len(D.interf))
    rec.update(shift_frames=int(fs), onset_shift_frames=int(f0), g=float(g), sir_target_db=float(D.sir_db),
               sir_measured_db=db(pt / pact(gi, ia)), overlap_frames=int(np.sum(ia & a_d)),
               overlap_share=float(np.sum(ia & a_d) / a_d.sum()), interf_active_frames=int(ia.sum()),
               padded_share=float(1.0 - max(0, hi - lo) / n), **s3)
    return Placed(mix.astype(np.float32), y.astype(np.float32), ia, rec, np.asarray(d.target, np.float32), a_d,
                  gi.astype(np.float32), ia)


def place_absent(fam: str, D: Donor, gain_rng: np.random.Generator) -> Placed:
    """W5's T2 absent case on the donor's own mixture (N: S1 donor, interferers removed, noise x U[0, 15] dB)."""
    rec = {"family": fam, "absent": True, "donor": [D.family, D.index]}
    if fam == "N":
        gdb = float(gain_rng.uniform(*N_GAIN_DB))
        g = np.float32(10.0 ** (gdb / 20.0))
        y = g * D.noise
        mix = D.target + y
        labels = np.asarray(D.target_active, bool)
        rec["n_gain_db"] = gdb
    else:
        mix = D.target + D.interf + D.noise
        y = D.noise
        labels = np.asarray(D.target_active, bool) | np.asarray(D.interferer_active, bool)
    return Placed(np.asarray(mix, np.float32), np.asarray(y, np.float32), labels, rec)


def _peak(p: Placed) -> Placed:
    peak = float(np.max(np.abs(p.mix), initial=0.0))
    p.record["peak_scale"] = 1.0
    if peak > PEAK:
        k = np.float32(PEAK / peak)
        p.mix, p.y = (p.mix * k).astype(np.float32), (p.y * k).astype(np.float32)
        if p.interf is not None:
            p.interf = (p.interf * k).astype(np.float32)
        if p.d_target is not None:
            p.d_target = (p.d_target * k).astype(np.float32)
        p.record["peak_scale"] = float(k)
    return p


def make_example(subject: str, k: int, dictations: list[Dictation], bank, seed: int = 0) -> Placed:
    """Example k of subject s: draws, placement, levelling, peak (DESIGN 2.4)."""
    if len(dictations) != 10:
        raise ValueError("the tuning stream needs exactly the 10 tuning dictations")
    r = rngs(seed, subject, k)
    fam = FAMILIES[int(r["family"].choice(len(FAMILIES), p=np.asarray(FAMILY_WEIGHTS)))]
    absent = bool(r["absent"].random() < P_ABSENT)
    j = int(r["dict"].integers(len(dictations)))
    bank_fam = "S1" if fam == "N" else fam
    nb = bank.counts[bank_fam]
    if absent:
        i = int(r["donor"].integers(nb))
        p = place_absent(fam, bank.get(bank_fam, i), r["gain"])
        p.record.update(dictation=None, rejections=0)
        return _peak(p)
    d = dictations[j]
    if fam == "S0":
        p = Placed(d.audio.astype(np.float32), d.audio.astype(np.float32), np.zeros(frame_count(len(d.audio)), bool),
                   {"family": "S0", "absent": False, "donor": None})
        p.record.update(dictation=j, rejections=0)
        return _peak(p)
    for c in range(MAX_CANDIDATES):
        i = int(r["donor"].integers(nb))
        try:
            p = place_present(fam, d, bank.get(bank_fam, i), r["gain"])
        except Rejected:
            continue
        p.record.update(dictation=j, rejections=c)
        return _peak(p)
    raise RuntimeError(f"subject {subject} example {k}: {MAX_CANDIDATES} donors rejected")


def to_example(p: Placed, profile: np.ndarray):
    """W5's Example, so batches come from `lfspk.extract.data.prepare_batch` unchanged."""
    from lfspk.extract.data import Example

    if p.labels.shape != (frame_count(len(p.mix)),):
        raise AssertionError("label length differs from the contract frame count")
    return Example(audio=p.mix, target=p.y, interfering=np.asarray(p.labels, bool),
                   profile=np.asarray(profile, np.float32), info=p.record)


def load_dictations(subject: str, out=None) -> list[Dictation]:
    """The subject's 10 tuning dictations from the validated dict set (nixos)."""
    from .render import OUT, load_set
    from .subjects import N_TUNE

    keys = [f"{subject}-{j:02d}" for j in range(N_TUNE)]
    return [Dictation(d["audio"], d["target"], d["target_active"]) for _, d in load_set("dict", keys, out or OUT)]


__all__ = ["FAMILIES", "FAMILY_WEIGHTS", "P_ABSENT", "Donor", "Bank", "Dictation", "Placed", "Rejected", "rngs",
           "s3_shift", "place_present", "place_absent", "make_example", "to_example", "load_dictations"]
