"""W1 voiceprint: what LocalFlow would store (before encryption).

Byte layout (little endian), format version 2:

    offset size  field
    0      4     magic b"LFW1"
    4      1     format version (2)
    5      1     embedder code (EMBEDDER_CODES)
    6      2     uint16 embedding dimension D
    8      1     uint8 number of centroids K (1..MAX_CENTROIDS)
    9      1     flags: bit 0 = an anchor vector follows the centroids; other bits zero
    10     2     uint16 dictations seen (enroll + update), saturating at 65535
    12     2     uint16 dictations accepted into the profile, saturating
    14     K x (2 + 4D)  per centroid: uint16 count n (1..65535, saturating), then
                 D float32 values of the running mean m of the unit dictation
                 embeddings folded into it (not normalised; 0 < |m| <= 1)
    ...    4D    if flags bit 0: D float32 values of the anchor, the unit
                 enrollment-time centroid direction (never updated)

Invariants checked on load: zero unused flag bits, 1 <= n, accepted <= seen,
n <= accepted for every centroid (unless saturated), finite vectors, centroid
norm in (0, 1 + 1e-4], anchor norm 1 +- 1e-4.

Nothing else: no audio, no per-dictation embeddings, no second moments, no
per-user score statistics. A single 192-dimensional centroid is 784 bytes,
1552 with an anchor. Counters saturate at 65535 so the file never holds
lifetime totals (W4, STORAGE.md section 1: they are allowed only inside the
ciphertext). Storing the unnormalised mean with its count (the definition W4
analyses) at float32 keeps the running mean m' = m + (d - m) / (n + 1)
accurate across persisted updates (float16 lost small updates at large n);
the update is exact up to float32 rounding until the count saturates at
65535, after which the rate stays 1 / 65536. Scoring uses the direction
m / |m|. One centroid per profile: the scorer API has no microphone-route
argument, so per-route centroids are not used.
"""

from __future__ import annotations

import struct
from dataclasses import dataclass

import numpy as np

MAGIC = b"LFW1"
VERSION = 2
MAX_CENTROIDS = 8
COUNT_MAX = 65535
FLAG_ANCHOR = 1
EMBEDDER_CODES = {
    "ecapa-vox": 1, "titanet-s": 2, "titanet-l": 3, "wespeaker-r34lm": 4,
    "wespeaker-campp": 5, "redimnet2-b0": 6, "redimnet2-b2": 7,
}
_CODE_NAMES = {v: k for k, v in EMBEDDER_CODES.items()}
_HEADER = struct.Struct("<4sBBHBBHH")
_NORM_TOL = 1e-4


@dataclass
class EmbProfile:
    embedder: str
    centroids: np.ndarray  # (K, D) float32 running means of unit vectors (norm in (0, 1])
    counts: np.ndarray  # (K,) int, dictations folded into each centroid (>= 1)
    seen: int = 0
    accepted: int = 0
    anchor: np.ndarray | None = None  # (D,) unit enrollment-time direction, or None

    def __post_init__(self):
        c = np.atleast_2d(np.asarray(self.centroids, np.float32))
        if self.embedder not in EMBEDDER_CODES:
            raise ValueError(f"unknown embedder {self.embedder!r}")
        if not 1 <= c.shape[0] <= MAX_CENTROIDS:
            raise ValueError("need 1..MAX_CENTROIDS centroids")
        norms = np.linalg.norm(c, axis=1)
        if not np.isfinite(c).all() or (norms <= 0).any() or (norms > 1.0 + _NORM_TOL).any():
            raise ValueError("centroids must be finite, non-zero means of unit vectors (norm <= 1)")
        self.centroids = c
        self.counts = np.minimum(np.asarray(self.counts, np.int64).reshape(-1), COUNT_MAX)
        self.seen, self.accepted = min(int(self.seen), COUNT_MAX), min(int(self.accepted), COUNT_MAX)
        if self.counts.shape[0] != c.shape[0] or (self.counts < 1).any():
            raise ValueError("one count >= 1 per centroid")
        if not 0 <= self.accepted <= self.seen:
            raise ValueError("need 0 <= accepted <= seen")
        if self.accepted < COUNT_MAX and (self.counts > self.accepted).any():
            raise ValueError("a centroid count exceeds the accepted dictations")
        if self.anchor is not None:
            a = np.asarray(self.anchor, np.float32).reshape(-1)
            if a.shape[0] != c.shape[1] or not np.isfinite(a).all() or abs(np.linalg.norm(a) - 1) > _NORM_TOL:
                raise ValueError("anchor must be a finite unit vector of the profile's dimension")
            self.anchor = a

    @property
    def directions(self) -> np.ndarray:
        """(K, D) L2-normalised centroids, used for scoring."""
        return (self.centroids / np.linalg.norm(self.centroids, axis=1, keepdims=True)).astype(np.float32)

    @property
    def dim(self) -> int:
        return int(self.centroids.shape[1])

    def to_bytes(self) -> bytes:
        k, d = self.centroids.shape
        flags = FLAG_ANCHOR if self.anchor is not None else 0
        out = [_HEADER.pack(MAGIC, VERSION, EMBEDDER_CODES[self.embedder], d, k, flags, self.seen, self.accepted)]
        for i in range(k):
            out.append(struct.pack("<H", int(self.counts[i])))
            out.append(self.centroids[i].astype("<f4").tobytes())
        if self.anchor is not None:
            out.append(self.anchor.astype("<f4").tobytes())
        return b"".join(out)

    @classmethod
    def from_bytes(cls, data: bytes) -> "EmbProfile":
        if len(data) < _HEADER.size:
            raise ValueError("profile too short")
        magic, version, code, d, k, flags, seen, accepted = _HEADER.unpack_from(data, 0)
        if magic != MAGIC or version != VERSION or code not in _CODE_NAMES:
            raise ValueError("not a W1 profile (magic, version or embedder code)")
        if flags & ~FLAG_ANCHOR:
            raise ValueError("unknown flag bits set")
        has_anchor = bool(flags & FLAG_ANCHOR)
        if not 1 <= k <= MAX_CENTROIDS or len(data) != cls.size_bytes(d, k, has_anchor):
            raise ValueError("profile length does not match its header")
        cents, counts, off = [], [], _HEADER.size
        for _ in range(k):
            counts.append(struct.unpack_from("<H", data, off)[0])
            off += 2
            cents.append(np.frombuffer(data, "<f4", d, off).astype(np.float32))
            off += 4 * d
        anchor = np.frombuffer(data, "<f4", d, off).astype(np.float32) if has_anchor else None
        return cls(_CODE_NAMES[code], np.stack(cents), np.array(counts), seen, accepted, anchor)

    @staticmethod
    def size_bytes(dim: int, centroids: int = 1, anchor: bool = False) -> int:
        return _HEADER.size + centroids * (2 + 4 * dim) + (4 * dim if anchor else 0)

    def quantised(self) -> "EmbProfile":
        """The profile as it would be after a store/load round trip."""
        return EmbProfile.from_bytes(self.to_bytes())
