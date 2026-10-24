"""Speaker back end fitted on train only (DESIGN 5.3): standardise, shrinkage LDA,
centre, length-normalise; cosine scoring against averaged enrollment models.
"""

from __future__ import annotations

from dataclasses import dataclass

import numpy as np
import scipy.linalg

LDA_DIM = 200


def _ledoit_wolf_shrinkage(xc: np.ndarray) -> float:
    """Ledoit-Wolf shrinkage intensity for centred data xc [n, d] towards mu*I."""
    from sklearn.covariance import ledoit_wolf_shrinkage

    return float(ledoit_wolf_shrinkage(xc, assume_centered=True))


@dataclass
class Backend:
    mean: np.ndarray  # [d] standardisation
    scale: np.ndarray  # [d]
    proj: np.ndarray  # [d, k]
    center: np.ndarray  # [k] mean of projected train data
    shrinkage: float

    @classmethod
    def fit(cls, x: np.ndarray, y: np.ndarray, dim: int = LDA_DIM) -> "Backend":
        """x [n, d] train features, y [n] speaker labels (any hashable, via np.unique)."""
        x = np.asarray(x, dtype=np.float64)
        classes, yi = np.unique(np.asarray(y), return_inverse=True)
        if classes.size < 2:
            raise ValueError("need at least two speakers")
        mean = x.mean(0)
        scale = x.std(0)
        scale = np.where(scale > 1e-8, scale, 1.0)
        z = (x - mean) / scale
        counts = np.bincount(yi).astype(np.float64)
        means = np.zeros((classes.size, z.shape[1]))
        np.add.at(means, yi, z)
        means /= counts[:, None]
        within = z - means[yi]
        n, d = z.shape
        sw = within.T @ within / n
        shrink = _ledoit_wolf_shrinkage(within)
        mu = np.trace(sw) / d
        sw = (1 - shrink) * sw + shrink * mu * np.eye(d)
        mc = means - (counts[:, None] * means).sum(0) / n
        sb = (counts[:, None] * mc).T @ mc / n
        k = int(min(dim, classes.size - 1, d))
        evals, evecs = scipy.linalg.eigh(sb, sw)
        proj = evecs[:, ::-1][:, :k]
        center = (z @ proj).mean(0)
        return cls(mean, scale, proj, center, shrink)

    def transform(self, x: np.ndarray) -> np.ndarray:
        """[n, d] -> [n, k], centred and length-normalised."""
        z = (np.asarray(x, dtype=np.float64) - self.mean) / self.scale
        e = z @ self.proj - self.center
        return l2norm(e)

    def to_npz(self) -> dict:
        return {"mean": self.mean, "scale": self.scale, "proj": self.proj, "center": self.center,
                "shrinkage": np.array(self.shrinkage)}

    @classmethod
    def from_npz(cls, d) -> "Backend":
        return cls(d["mean"], d["scale"], d["proj"], d["center"], float(d["shrinkage"]))


def l2norm(e: np.ndarray) -> np.ndarray:
    n = np.linalg.norm(e, axis=-1, keepdims=True)
    return e / np.maximum(n, 1e-12)


def enrollment_model(embs: np.ndarray) -> np.ndarray:
    """Mean of length-normalised embeddings [m, k], renormalised -> [k]."""
    return l2norm(l2norm(np.asarray(embs, dtype=np.float64)).mean(0))


def cosine_matrix(models: np.ndarray, tests: np.ndarray) -> np.ndarray:
    """[M, k] x [T, k] -> [M, T] cosine scores (inputs normalised here)."""
    return l2norm(models) @ l2norm(tests).T
