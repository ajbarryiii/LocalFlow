"""Protection transforms for a speaker profile (DESIGN.md section 6.1).

Persisted state. Per microphone route LocalFlow would store exactly
(count n, template) and nothing else: no seed, no noise realisation, no raw
mean. The profile underneath is the running mean s_n = mean_k x_k of the
per-utterance L2-normalised embeddings (unnormalised); the raw centroid
direction is l2n(s_n).

A protection is public: under the threat model (A3) the attacker has every
fitted parameter, the cohort and any key. Structure:

    state    = base.project(s_n)            affine, so it commutes with averaging
    template = encoder.encode(state)        what is stored
    probe    = base.forward(x)              in memory only: l2n(project(l2n(x)))
    score    = encoder.decode(template) . probe   (cosine; asymmetric)

Bases (all affine x -> (x - mu) W): raw (identity), center, PCA, LDA, anchor
scores, keyed rotation. Encoders: float32 state (the persisted format; running-mean update),
b-bit quantiser, sign bits of random hyperplanes, additive noise (the last
three act on the normalised state). `LinearFunction` stores logistic-regression
weights trained from the enrollment utterances against a public cohort.

All arrays are batched: rows are vectors.
"""

from __future__ import annotations

import math

import numpy as np
import scipy.linalg

EPS = 1e-12


def l2n(x: np.ndarray) -> np.ndarray:
    x = np.asarray(x, dtype=np.float64)
    return x / np.maximum(np.linalg.norm(x, axis=-1, keepdims=True), EPS)


def speaker_means(X: np.ndarray, y: np.ndarray) -> tuple[np.ndarray, np.ndarray]:
    """Per-speaker unnormalised means (the profile state definition)."""
    labels, inv = np.unique(y, return_inverse=True)
    M = np.zeros((labels.size, X.shape[1]))
    np.add.at(M, inv, X)
    M /= np.bincount(inv)[:, None]
    return labels, M


# ---------------------------------------------------------------- bases

class Base:
    """Affine map project(x) = (x - mu) W, fitted on public train embeddings."""

    name = "base"
    mu: np.ndarray  # [D]
    W: np.ndarray  # [D, p]

    def fit(self, X: np.ndarray, y: np.ndarray, rng: np.random.Generator | None) -> "Base":
        raise NotImplementedError

    @property
    def out_dim(self) -> int:
        return self.W.shape[1]

    def _finish_fit(self, X: np.ndarray, y: np.ndarray) -> None:
        _, M = speaker_means(X, y)
        self.typical_norm = float(np.median(np.linalg.norm(self.project(M), axis=1)))
        self.W_pinv = np.linalg.pinv(self.W)  # [p, D]

    def project(self, S: np.ndarray) -> np.ndarray:
        return (np.asarray(S, dtype=np.float64) - self.mu) @ self.W

    def forward(self, X: np.ndarray) -> np.ndarray:
        return l2n(self.project(l2n(X)))

    def inverse_state(self, Z: np.ndarray) -> np.ndarray:
        """Minimum-norm preimage of an (unnormalised) projected state, normalised."""
        return l2n(self.mu + np.asarray(Z, dtype=np.float64) @ self.W_pinv)

    def inverse(self, V: np.ndarray) -> np.ndarray:
        """Preimage of a unit direction in base space, at the train-typical norm."""
        return self.inverse_state(l2n(V) * self.typical_norm)


class Identity(Base):
    name = "raw"

    def fit(self, X, y, rng):
        D = X.shape[1]
        self.mu, self.W = np.zeros(D), np.eye(D)
        self._finish_fit(X, y)
        return self


class Center(Base):
    """Subtract the public train mean (needed before sign codes)."""

    name = "center"

    def fit(self, X, y, rng):
        self.mu, self.W = X.mean(axis=0), np.eye(X.shape[1])
        self._finish_fit(X, y)
        return self


class PCA(Base):
    def __init__(self, d: int):
        self.d = d
        self.name = f"pca{d}"

    def fit(self, X, y, rng):
        self.mu = X.mean(axis=0)
        _, _, Vt = np.linalg.svd(X - self.mu, full_matrices=False)
        self.W = Vt[: self.d].T
        self._finish_fit(X, y)
        return self


class LDA(Base):
    """Fisher LDA, within-class whitened (W^T Sw W = I), top d directions."""

    def __init__(self, d: int, shrink: float = 1e-3):
        self.d = d
        self.shrink = shrink
        self.name = f"lda{d}"

    def fit(self, X, y, rng):
        self.mu = X.mean(axis=0)
        _, M = speaker_means(X, y)
        _, inv = np.unique(y, return_inverse=True)
        Xc = X - M[inv]
        Sw = Xc.T @ Xc / len(X)
        Mc = M - self.mu
        Sb = Mc.T @ Mc / len(M)
        Sw = Sw + self.shrink * np.trace(Sw) / Sw.shape[0] * np.eye(Sw.shape[0])
        evals, evecs = scipy.linalg.eigh(Sb, Sw)
        order = np.argsort(evals)[::-1][: self.d]
        self.W = evecs[:, order]
        self._finish_fit(X, y)
        return self


class Anchors(Base):
    """Cosine scores against K public anchor speakers, centred by the train mean
    score vector: x A^T - m, written as (x - mu) A^T with the min-norm mu."""

    def __init__(self, k: int):
        self.k = k
        self.name = f"anchor{k}"

    def fit(self, X, y, rng):
        labels, M = speaker_means(X, y)
        pick = np.sort(rng.choice(labels.size, self.k, replace=False))
        self.anchor_speakers = labels[pick]
        A = l2n(M[pick])  # [K, D]
        m = (l2n(X) @ A.T).mean(axis=0)
        self.mu = m @ np.linalg.pinv(A.T)
        self.W = A.T
        self._finish_fit(X, y)
        return self


class KeyedRotation(Base):
    """Secret random orthogonal rotation. Equivalent to raw for scoring; only the
    key separates it from raw, so under full compromise it is raw."""

    def __init__(self, key: int):
        self.key = key
        self.name = "keyrot"

    def fit(self, X, y, rng):
        D = X.shape[1]
        G = np.random.default_rng([self.key, 0x6B6579]).standard_normal((D, D))
        Q, R = np.linalg.qr(G)
        self.mu, self.W = np.zeros(D), Q * np.sign(np.diag(R))
        self._finish_fit(X, y)
        return self


# ---------------------------------------------------------------- encoders

class Encoder:
    """Stores the unnormalised projected running mean as float32, as W1's
    persisted profile does (float16 was dropped after W1's review: it stops
    absorbing updates at high counts)."""

    name = "f32"
    exact_update = True

    def fit(self, Z: np.ndarray, rng: np.random.Generator) -> "Encoder":
        self.p = Z.shape[1]
        return self

    def encode(self, Z: np.ndarray, rng: np.random.Generator | None = None) -> np.ndarray:
        return np.asarray(Z, dtype=np.float32)

    def decode(self, T: np.ndarray) -> np.ndarray:
        """Template -> unit direction in base space (for scoring)."""
        return l2n(T)

    def features(self, T: np.ndarray) -> np.ndarray:
        """Everything the stored template reveals, as floats (for attackers)."""
        return np.asarray(T, dtype=np.float64)

    def to_bytes(self, t: np.ndarray) -> bytes:
        return np.asarray(t, dtype="<f4").tobytes()

    def stored_bits(self) -> int:
        return 32 * self.p


class Quantizer(Encoder):
    """Per-dimension uniform mid-rise quantiser with 2^b levels on [-s_j, s_j]
    of the normalised state; s_j the 99.5th percentile of |v_j| over train
    speaker states. b = 1 is the coordinate sign."""

    exact_update = False

    def __init__(self, bits: int):
        if bits < 1 or bits > 8:
            raise ValueError("bits in 1..8")
        self.bits = bits
        self.name = f"q{bits}"

    def fit(self, Z, rng):
        self.p = Z.shape[1]
        self.scale = np.maximum(np.quantile(np.abs(l2n(Z)), 0.995, axis=0), EPS)
        return self

    def encode(self, Z, rng=None):
        L = 2 ** self.bits
        u = (np.clip(l2n(Z) / self.scale, -1.0, 1.0) + 1.0) / 2.0 * L
        return np.clip(np.floor(u), 0, L - 1).astype(np.uint8)

    def decode(self, T):
        L = 2 ** self.bits
        return l2n(((np.asarray(T, dtype=np.float64) + 0.5) / L * 2.0 - 1.0) * self.scale)

    def features(self, T):
        return self.decode(T)  # an injective re-expression of the codes

    def to_bytes(self, t):
        bits = ((np.asarray(t)[:, None] >> np.arange(self.bits)) & 1).astype(np.uint8).ravel()
        return np.packbits(bits).tobytes()

    def stored_bits(self):
        return self.bits * self.p


class SimHash(Encoder):
    """m sign bits of public Gaussian hyperplanes applied to the state."""

    exact_update = False

    def __init__(self, m: int, seed: int):
        self.m = m
        self.seed = seed
        self.name = f"sh{m}"

    def fit(self, Z, rng):
        self.p = Z.shape[1]
        self.H = np.random.default_rng([self.seed, 0x5348]).standard_normal((self.p, self.m))
        return self

    def encode(self, Z, rng=None):
        return (np.asarray(Z, dtype=np.float64) @ self.H > 0).astype(np.uint8)

    def decode(self, T):
        # Sum of signed hyperplanes: the direction estimate under an isotropic prior.
        return l2n((2.0 * np.asarray(T, dtype=np.float64) - 1.0) @ self.H.T)

    def features(self, T):
        return 2.0 * np.asarray(T, dtype=np.float64) - 1.0  # the bits themselves

    def to_bytes(self, t):
        return np.packbits(np.asarray(t, dtype=np.uint8)).tobytes()

    def stored_bits(self):
        return self.m


class SimHashVotes(Encoder):
    """Per-bit vote fractions of m public Gaussian hyperplanes over the
    dictations folded in (what a background-updated sign code must keep to
    update by majority). Stored as uint16 fixed point. Exact update by adding
    counts; adaptation experiment only. Evaluated as its own protection so the
    extra leakage of counts over signs gets the full attack suite."""

    exact_update = False
    per_utterance = True

    def __init__(self, m: int, seed: int):
        self.m = m
        self.seed = seed
        self.name = f"shv{m}"

    def fit(self, Z, rng):
        self.p = Z.shape[1]
        self.H = SimHash(self.m, self.seed).fit(Z, rng).H  # same planes as SimHash(m, seed)
        return self

    def encode_utterances(self, V: np.ndarray) -> np.ndarray:
        """V [k, p] unit base vectors of one profile's dictations -> fractions [m]."""
        return (V @ self.H > 0).mean(axis=0)

    def encode(self, Z, rng=None):
        raise TypeError("vote fractions need per-dictation vectors (encode_utterances)")

    def decode(self, T):
        return l2n((2.0 * np.asarray(T, dtype=np.float64) - 1.0) @ self.H.T)

    def features(self, T):
        return np.asarray(T, dtype=np.float64)

    def to_bytes(self, t):
        return np.round(np.asarray(t, dtype=np.float64) * 65535).astype("<u2").tobytes()

    def stored_bits(self):
        return 16 * self.m


class Noise(Encoder):
    """normalise(l2n(state) + s g / sqrt(p)), g ~ N(0, I) drawn once per template
    from a CSPRNG in the product and never stored. Experiments draw g from a
    recorded seed for reproducibility; only the "seedleak" attacker may use it."""

    exact_update = False

    def __init__(self, s: float):
        self.s = s
        self.name = f"noise{s:g}"

    def noise(self, shape: tuple[int, int], rng: np.random.Generator) -> np.ndarray:
        return self.s * rng.standard_normal(shape) / math.sqrt(shape[1])

    def encode(self, Z, rng=None):
        if rng is None:
            raise ValueError("Noise.encode needs an rng")
        return l2n(l2n(Z) + self.noise(Z.shape, rng)).astype(np.float32)

    def features(self, T):
        return np.asarray(T, dtype=np.float64)

    @staticmethod
    def undo(T: np.ndarray, N: np.ndarray) -> np.ndarray:
        """Exact inverse given the noise realisation N: t = l2n(v + N), |v| = 1,
        so v = a t - N with a > 0 solving |a t - N| = 1."""
        t = l2n(T)
        tn = np.sum(t * N, axis=1)
        a = tn + np.sqrt(np.maximum(tn ** 2 - np.sum(N * N, axis=1) + 1.0, 0.0))
        return l2n(a[:, None] * t - N)


# ---------------------------------------------------------------- protections

class Protection:
    """A public protection: fit on train embeddings, protect profiles."""

    name: str

    def fit(self, X: np.ndarray, y: np.ndarray, seed: int) -> "Protection":
        raise NotImplementedError

    def protect_from_utterances(self, E: list[np.ndarray], rng: np.random.Generator | None = None) -> np.ndarray:
        """Templates from per-profile utterance embeddings ([k_i, D] each)."""
        raise NotImplementedError

    def probe(self, X: np.ndarray) -> np.ndarray:
        raise NotImplementedError

    def score(self, T: np.ndarray, P: np.ndarray) -> np.ndarray:
        """[m templates] x [n probes] -> [m, n] similarities."""
        raise NotImplementedError

    def features(self, T: np.ndarray) -> np.ndarray:
        """Everything the template reveals, as a float matrix, for attackers."""
        raise NotImplementedError

    def analytic_inverse(self, T: np.ndarray) -> np.ndarray | None:
        return None

    def to_bytes(self, t: np.ndarray) -> bytes:
        raise NotImplementedError

    def stored_bits(self) -> int:
        raise NotImplementedError


class Composed(Protection):
    def __init__(self, base: Base, encoder: Encoder | None = None):
        self.base = base
        self.encoder = encoder or Encoder()
        self.name = base.name if self.encoder.name == "f32" else f"{base.name}+{self.encoder.name}"

    def fit(self, X, y, seed):
        rng = np.random.default_rng([seed, 0xF17])
        self.base.fit(X, y, rng)
        _, M = speaker_means(X, y)
        self.encoder.fit(self.base.project(M), rng)  # templates are speaker means
        return self

    def state(self, E: list[np.ndarray]) -> np.ndarray:
        """Projected running-mean state of each profile's utterances."""
        return self.base.project(np.stack([l2n(e).mean(axis=0) for e in E]))

    def protect_from_utterances(self, E, rng=None):
        if getattr(self.encoder, "per_utterance", False):
            return np.stack([self.encoder.encode_utterances(self.base.forward(e)) for e in E])
        return self.encoder.encode(self.state(E), rng)

    def update(self, T: np.ndarray, n: np.ndarray, x: np.ndarray) -> np.ndarray:
        """Fold one more utterance embedding per profile (rows of x) into float
        templates of n utterances each: running mean in the protected domain
        (exact up to float32 storage). Other encoders have no exact update (adaptation experiment)."""
        if not self.encoder.exact_update:
            raise NotImplementedError(f"{self.name} has no exact protected-domain update")
        T = np.asarray(T, dtype=np.float64)
        n = np.asarray(n, dtype=np.float64)[:, None]
        return self.encoder.encode(T + (self.base.project(l2n(x)) - T) / (n + 1))

    def probe(self, X):
        return self.base.forward(X)

    def score(self, T, P):
        return self.encoder.decode(T) @ l2n(P).T

    def features(self, T):
        return self.encoder.features(T)

    def analytic_inverse(self, T):
        if type(self.encoder) is Encoder:  # unnormalised state: exact where W is invertible
            return self.base.inverse_state(T)
        return self.base.inverse(self.encoder.decode(T))

    def to_bytes(self, t):
        return self.encoder.to_bytes(t)

    def stored_bits(self):
        return self.encoder.stored_bits()


class LinearFunction(Protection):
    """Store a logistic-regression decision function (w, b) trained on device:
    the k enrollment embeddings (centred) against a public cohort (200 train
    speakers x their first 10 cached utterances), classes balanced, L2 penalty
    lam * |w|^2 (lam fixed a priori at 1e-3, not tuned). The parameters are a
    nonlinear function of the enrollment set (not a linear map of its mean)."""

    def __init__(self, cohort_speakers: int = 200, lam: float = 1e-3, steps: int = 300,
                 cohort_utts: int = 10):
        self.cohort_speakers = cohort_speakers
        self.cohort_utts = cohort_utts
        self.lam = lam
        self.steps = steps
        self.name = "linfn"

    def fit(self, X, y, seed):
        rng = np.random.default_rng([seed, 0xC0])
        labels = np.unique(y)
        n_coh = min(self.cohort_speakers, labels.size // 4)  # 200 on the real train split
        self.cohort = np.sort(rng.choice(labels, n_coh, replace=False))
        self.mu = X.mean(axis=0)
        rows = np.concatenate([np.flatnonzero(y == s)[: self.cohort_utts] for s in self.cohort])
        self.N = l2n(X[rows]) - self.mu
        self.out_dim = X.shape[1] + 1
        return self

    def protect_from_utterances(self, E, rng=None):
        import torch

        D = self.N.shape[1]
        k = max(len(e) for e in E)
        P = np.zeros((len(E), k, D))
        mask = np.zeros((len(E), k))
        for i, e in enumerate(E):
            P[i, : len(e)] = l2n(e) - self.mu
            mask[i, : len(e)] = 1.0
        Pt = torch.tensor(P, dtype=torch.float64)
        Mt = torch.tensor(mask, dtype=torch.float64)
        Nt = torch.tensor(self.N, dtype=torch.float64)
        w = torch.zeros(len(E), D, dtype=torch.float64, requires_grad=True)
        b = torch.zeros(len(E), dtype=torch.float64, requires_grad=True)
        opt = torch.optim.LBFGS([w, b], lr=1.0, max_iter=self.steps, tolerance_grad=1e-10,
                                tolerance_change=1e-14, history_size=20, line_search_fn="strong_wolfe")

        def closure():
            opt.zero_grad()
            pos = torch.einsum("pkd,pd->pk", Pt, w) + b[:, None]
            neg = Nt @ w.T + b[None, :]  # [n, P]
            lp = (torch.nn.functional.softplus(-pos) * Mt).sum(1) / Mt.sum(1)
            ln = torch.nn.functional.softplus(neg).mean(0)
            loss = (0.5 * lp + 0.5 * ln + self.lam * (w * w).sum(1)).sum()
            loss.backward()
            return loss

        opt.step(closure)
        return torch.cat([w.detach(), b.detach()[:, None]], dim=1).numpy().astype(np.float32)

    def probe(self, X):
        return l2n(X) - self.mu

    def score(self, T, P):
        T = np.asarray(T, dtype=np.float64)
        return T[:, :-1] @ P.T + T[:, -1:]

    def features(self, T):
        return np.asarray(T, dtype=np.float64)

    def analytic_inverse(self, T):
        """KKT inversion. At the optimum, d/dw and d/db vanish:
            mean_k sig(-s_k) x_k = mean_n sig(s_n) x_n + 4 lam w
            mean_k sig(-s_k)     = mean_n sig(s_n)
        so the sig(-s)-weighted mean of the enrollment embeddings equals a
        quantity computable from (w, b) and the public cohort."""
        T = np.asarray(T, dtype=np.float64)
        w, b = T[:, :-1], T[:, -1]
        sig = 1.0 / (1.0 + np.exp(-(self.N @ w.T + b[None, :])))  # [n, P]
        num = (sig.T @ self.N) / len(self.N) + 4.0 * self.lam * w
        den = sig.mean(axis=0)[:, None]
        return l2n(num / den + self.mu)

    def to_bytes(self, t):
        return np.asarray(t, dtype="<f4").tobytes()

    def stored_bits(self):
        return 32 * self.out_dim


def build(name: str, seed: int, key: int = 0xA11CE) -> Protection:
    """Protection by grid name (DESIGN.md section 6.1)."""
    parts = name.split("+")
    head = parts[0]
    if head == "raw":
        base: Base = Identity()
    elif head == "center":
        base = Center()
    elif head.startswith("pca"):
        base = PCA(int(head[3:]))
    elif head.startswith("lda"):
        base = LDA(int(head[3:]))
    elif head.startswith("anchor"):
        base = Anchors(int(head[6:]))
    elif head == "keyrot":
        base = KeyedRotation(key)
    elif head == "linfn":
        if len(parts) > 1:
            raise ValueError("linfn takes no encoder")
        return LinearFunction()
    else:
        raise ValueError(f"unknown base {head!r}")
    if len(parts) == 1:
        return Composed(base)
    if len(parts) != 2:
        raise ValueError(f"one encoder at most: {name!r}")
    enc = parts[1]
    if enc.startswith("q"):
        encoder: Encoder = Quantizer(int(enc[1:]))
    elif enc.startswith("shv"):
        encoder = SimHashVotes(int(enc[3:]), seed)
    elif enc.startswith("sh"):
        encoder = SimHash(int(enc[2:]), seed)
    elif enc.startswith("noise"):
        encoder = Noise(float(enc[5:]))
    else:
        raise ValueError(f"unknown encoder {enc!r}")
    return Composed(base, encoder)


# The fixed grid (DESIGN.md 6.1). Quantisers and sign codes need a centred base.
GRID: tuple[str, ...] = (
    "raw",
    "pca16", "pca32", "pca64",
    "lda16", "lda32", "lda64",
    "center+q1", "center+q2", "center+q4",
    "lda32+q1", "lda32+q2", "lda32+q4",
    "center+sh32", "center+sh64", "center+sh128", "center+sh256",
    "lda32+sh32", "lda32+sh64", "lda32+sh128", "lda32+sh256",
    "anchor16", "anchor32", "anchor64", "anchor128",
    "anchor64+q1", "anchor128+q1",
    "center+noise0.25", "center+noise0.5", "center+noise1",
    "linfn",
    "keyrot",
    "lda32+noise0.5", "anchor64+noise0.5",
    # added after review clone-r1 #5 (before any run): vote counts that a
    # background-updated sign code must keep, on the adaptation configurations
    "center+shv128", "lda32+shv64",
)
