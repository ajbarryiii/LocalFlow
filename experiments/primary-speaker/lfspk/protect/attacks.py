"""Inversion attackers: protected template -> estimate of the raw centroid.

Every attacker is trained only on train-split pseudo-profiles (pairs of a
protected template and its raw centroid) and selects its hyperparameters on
held-out train speakers, never on dev (DESIGN.md section 6.3). The A3 attacker
knows the protection object, so it can also use the protection's own analytic
inverse and its scorer.
"""

from __future__ import annotations

from dataclasses import dataclass

import numpy as np

from .transforms import Protection, l2n


def mean_cos(A: np.ndarray, B: np.ndarray) -> float:
    return float(np.mean(np.sum(l2n(A) * l2n(B), axis=1)))


class Attacker:
    name: str

    def fit(self, F_tr: np.ndarray, C_tr: np.ndarray, F_va: np.ndarray, C_va: np.ndarray) -> "Attacker":
        return self

    def invert(self, F: np.ndarray) -> np.ndarray:
        raise NotImplementedError


class Analytic(Attacker):
    """The protection's own inverse (pseudo-inverse, dequantisation, signed
    hyperplane sum, the key). Needs the template, not features."""

    name = "analytic"

    def __init__(self, protection: Protection):
        self.protection = protection

    def invert_templates(self, T: np.ndarray) -> np.ndarray | None:
        out = self.protection.analytic_inverse(T)
        return None if out is None else l2n(out)


class Ridge(Attacker):
    """Linear MMSE regression with an intercept; lambda chosen by validation cosine."""

    name = "ridge"
    LAMBDAS = (1e-4, 1e-3, 1e-2, 1e-1, 1.0, 10.0, 100.0)

    def _solve(self, F, C, lam):
        fm, cm = F.mean(0), C.mean(0)
        Fc = F - fm
        A = Fc.T @ Fc + lam * len(F) * np.eye(F.shape[1])
        W = np.linalg.solve(A, Fc.T @ (C - cm))
        return fm, cm, W

    def fit(self, F_tr, C_tr, F_va, C_va):
        best = None
        for lam in self.LAMBDAS:
            fm, cm, W = self._solve(F_tr, C_tr, lam)
            c = mean_cos((F_va - fm) @ W + cm, C_va)
            if best is None or c > best[0]:
                best = (c, lam)
        self.lam = best[1]
        self.val_cos = best[0]
        self.fm, self.cm, self.W = self._solve(np.vstack([F_tr, F_va]), np.vstack([C_tr, C_va]), self.lam)
        return self

    def invert(self, F):
        return l2n((F - self.fm) @ self.W + self.cm)


class MLP(Attacker):
    """Two hidden layers (GELU), AdamW, early stopping on the validation
    speakers. CPU. loss="cos": unit-direction targets (inversion to an
    embedding); loss="mse": unnormalised targets (e.g. OpenVoice se)."""

    def __init__(self, seed: int, hidden: int = 512, epochs: int = 200, patience: int = 15,
                 lr: float = 1e-3, wd: float = 1e-4, batch: int = 512, loss: str = "cos"):
        if loss not in ("cos", "mse"):
            raise ValueError(loss)
        self.loss = loss
        self.seed = seed
        self.hidden = hidden
        self.epochs = epochs
        self.patience = patience
        self.lr = lr
        self.wd = wd
        self.batch = batch
        self.name = f"mlp-s{seed}" if loss == "cos" else f"mlpmse-s{seed}"

    def _out(self, net, X):
        import torch

        y = net(X)
        return torch.nn.functional.normalize(y, dim=1) if self.loss == "cos" else y * self.ys + self.ym

    def _val(self, out, Y):
        if self.loss == "cos":
            return float((out * Y).sum(1).mean())
        return -float(((out - Y) ** 2).sum(1).mean())  # higher is better

    def fit(self, F_tr, C_tr, F_va, C_va):
        import torch

        torch.manual_seed(self.seed)
        g = torch.Generator().manual_seed(self.seed)
        self.fm = F_tr.mean(0)
        self.fs = F_tr.std(0) + 1e-6
        f_in, d_out = F_tr.shape[1], C_tr.shape[1]
        net = torch.nn.Sequential(
            torch.nn.Linear(f_in, self.hidden), torch.nn.GELU(),
            torch.nn.Linear(self.hidden, self.hidden), torch.nn.GELU(),
            torch.nn.Linear(self.hidden, d_out),
        ).double()
        opt = torch.optim.AdamW(net.parameters(), lr=self.lr, weight_decay=self.wd)
        Xt = torch.tensor((F_tr - self.fm) / self.fs)
        Xv = torch.tensor((F_va - self.fm) / self.fs)
        if self.loss == "cos":
            Yt, Yv = torch.tensor(l2n(C_tr)), torch.tensor(l2n(C_va))
        else:
            self.ym, self.ys = torch.tensor(C_tr.mean(0)), torch.tensor(C_tr.std(0) + 1e-6)
            Yt, Yv = torch.tensor(C_tr), torch.tensor(C_va)
        best_cos, best_state, bad = -np.inf, None, 0
        for epoch in range(self.epochs):
            net.train()
            perm = torch.randperm(len(Xt), generator=g)
            for i in range(0, len(Xt), self.batch):
                idx = perm[i : i + self.batch]
                out = self._out(net, Xt[idx])
                if self.loss == "cos":
                    loss = 1.0 - (out * Yt[idx]).sum(1).mean()
                else:
                    loss = (((out - Yt[idx]) / self.ys) ** 2).sum(1).mean()
                opt.zero_grad()
                loss.backward()
                opt.step()
            net.eval()
            with torch.no_grad():
                vc = self._val(self._out(net, Xv), Yv)
            if vc > best_cos + 1e-5:
                best_cos, bad = vc, 0
                best_state = {k: v.clone() for k, v in net.state_dict().items()}
            else:
                bad += 1
                if bad >= self.patience:
                    break
        net.load_state_dict(best_state)
        self.net = net
        self.val_cos = best_cos  # validation cosine (cos) or minus MSE (mse)
        self.epochs_run = epoch + 1
        return self

    def invert(self, F):
        import torch

        with torch.no_grad():
            out = self._out(self.net, torch.tensor((F - self.fm) / self.fs)).numpy()
        return l2n(out) if self.loss == "cos" else out


class RidgeMSE(Ridge):
    """Ridge regression to unnormalised targets, lambda chosen by validation MSE."""

    name = "ridgemse"

    def fit(self, F_tr, C_tr, F_va, C_va):
        best = None
        for lam in self.LAMBDAS:
            fm, cm, W = self._solve(F_tr, C_tr, lam)
            err = float((((F_va - fm) @ W + cm - C_va) ** 2).sum(1).mean())
            if best is None or err < best[0]:
                best = (err, lam)
        self.lam, self.val_mse = best[1], best[0]
        self.fm, self.cm, self.W = self._solve(np.vstack([F_tr, F_va]), np.vstack([C_tr, C_va]), self.lam)
        return self

    def invert(self, F):
        return (F - self.fm) @ self.W + self.cm


def _sign_solve(A, target, init, margin, rho, steps):
    import torch

    x = init.clone().requires_grad_(True)
    opt = torch.optim.LBFGS([x], lr=1.0, max_iter=steps, tolerance_grad=1e-12, tolerance_change=1e-15,
                            history_size=20, line_search_fn="strong_wolfe")

    def closure():
        opt.zero_grad()
        mar = torch.einsum("mp,mpk->mk", x, A)
        loss = ((x - target) ** 2).sum() + rho * (torch.relu(margin - mar) ** 2).sum()
        loss.backward()
        return loss

    opt.step(closure)
    return x.detach()


def sign_consistent(H: np.ndarray, bits: np.ndarray, x0: np.ndarray | None = None,
                    rho: float = 100.0, eps: float = 0.05, steps: int = 300,
                    return_feasible: bool = False):
    """Directions in base space consistent with stored sign bits.

    x0 None: maximum-margin direction, min |x|^2 s.t. b_i h_i.x / |h_i| >= 1,
    by a quadratic penalty. x0 given (unit rows): the nearest point to x0 with
    every constraint satisfied at margin eps. A finite penalty can leave
    violations: such rows are re-solved with rho x10 (up to three times); rows
    of the x0 variant still violating fall back to the maximum-margin solution.
    Returns unit rows, and with return_feasible a mask of rows that reproduce
    every stored bit."""
    import torch

    Hn = H / np.linalg.norm(H, axis=0, keepdims=True)
    A = torch.tensor((2.0 * bits - 1.0)[:, None, :] * Hn[None, :, :])  # [m, p, nbits]
    signed_sum = torch.tensor(l2n((2.0 * bits - 1.0) @ Hn.T))
    if x0 is None:
        target, margin, init = torch.zeros_like(signed_sum), 1.0, signed_sum
    else:
        target = torch.tensor(l2n(x0))
        margin, init = eps, target.clone()
    X = _sign_solve(A, target, init, margin, rho, steps).numpy()

    def ok(Z):
        return (((Z @ H) > 0).astype(np.uint8) == bits).all(axis=1)

    feas = ok(X)
    r = rho
    for _ in range(3):
        if feas.all():
            break
        r *= 10
        bad = np.flatnonzero(~feas)
        X[bad] = _sign_solve(A[bad], target[bad], torch.tensor(X[bad]), margin, r, steps).numpy()
        feas = ok(X)
    if x0 is not None and not feas.all():
        bad = np.flatnonzero(~feas)
        X[bad] = sign_consistent(H, bits[bad], None, rho, eps, steps)
        feas = ok(X)
    X = l2n(X)
    return (X, feas) if return_feasible else X


def _quant_cell(enc, T: np.ndarray, shrink: float) -> tuple[np.ndarray, np.ndarray]:
    """Bounds of the stored code's cell on the normalised state, intersected
    with [-1, 1] (a unit vector's coordinates), shrunk inward by `shrink`
    (in units of the cell width) on interior faces. Encoding is
    floor((clip(v / s, -1, 1) + 1) / 2 * L), so cell c is [lo, hi) with the
    outer codes open toward -1 and +1."""
    L = 2 ** enc.bits
    T = np.asarray(T, dtype=np.float64)
    width = 2.0 / L * enc.scale
    lo = np.where(T == 0, -1.0, (T / L * 2.0 - 1.0) * enc.scale + shrink * width)
    hi = np.where(T == L - 1, 1.0, ((T + 1.0) / L * 2.0 - 1.0) * enc.scale - shrink * width)
    return np.maximum(lo, -1.0), np.minimum(hi, 1.0)


def _unit_on_ray(d: np.ndarray, lo: np.ndarray, hi: np.ndarray, iters: int) -> np.ndarray:
    """clip(a d, lo, hi) with a > 0 chosen by bisection so its norm is as close
    to 1 as the ray allows (each |coordinate| is nondecreasing in a)."""
    a_lo, a_hi = np.zeros(len(d)), np.full(len(d), 1e3)
    for _ in range(iters):
        a = (a_lo + a_hi) / 2
        nrm = np.linalg.norm(np.clip(a[:, None] * d, lo, hi), axis=1)
        a_lo = np.where(nrm < 1.0, a, a_lo)
        a_hi = np.where(nrm < 1.0, a_hi, a)
    return np.clip(a_hi[:, None] * d, lo, hi)


def _unit_on_segment(lo: np.ndarray, hi: np.ndarray, iters: int) -> np.ndarray:
    """A point of norm 1 on the segment from the box's minimum-norm point to its
    maximum-norm corner (inside the box by convexity); exists iff the box meets
    the unit sphere."""
    pmin = np.clip(0.0, lo, hi)
    pmax = np.where(np.abs(lo) > np.abs(hi), lo, hi)
    t_lo, t_hi = np.zeros(len(lo)), np.ones(len(lo))
    for _ in range(iters):
        t = (t_lo + t_hi) / 2
        nrm = np.linalg.norm(pmin + t[:, None] * (pmax - pmin), axis=1)
        t_lo = np.where(nrm < 1.0, t, t_lo)
        t_hi = np.where(nrm < 1.0, t_hi, t)
    return pmin + t_hi[:, None] * (pmax - pmin)


def quant_consistent(enc, T: np.ndarray, x0: np.ndarray, iters: int = 80,
                     return_feasible: bool = False):
    """A unit vector whose quantiser code equals the stored code T, close to x0.

    Candidates, in order of preference, each accepted only if re-encoding it
    reproduces T exactly:
    1. along directions blending x0 toward the cell centre (t = 0 ... 1),
       scaled and clipped into the slightly shrunk cell until unit norm;
    2. the unit point on the segment from the cell's minimum-norm point to its
       maximum-norm corner (exists iff the cell meets the sphere), with the
       shrunk cell and then the exact cell (boundary-feasible cells, whose
       intersection with the sphere lies on the cell boundary).
    Rows where no candidate reproduces T are reported infeasible (the cell may
    not meet the sphere at all); they get the last candidate, normalised."""
    T = np.asarray(T)
    x0 = l2n(x0)
    out = np.zeros(T.shape, dtype=np.float64)
    done = np.zeros(len(T), dtype=bool)

    def consider(cand):
        nonlocal done
        cand = l2n(cand)
        good = (enc.encode(cand) == T).all(axis=1) & ~done
        out[good] = cand[good]
        done |= good

    lo, hi = _quant_cell(enc, T, 1e-6)
    mid = l2n((lo + hi) / 2)
    for t in (0.0, 0.25, 0.5, 0.75, 1.0):
        if done.all():
            break
        consider(_unit_on_ray(l2n((1 - t) * x0 + t * mid), lo, hi, iters))
    last = None
    for shrink in (1e-6, 1e-9, 0.0):
        if done.all():
            break
        lo, hi = _quant_cell(enc, T, shrink)
        last = _unit_on_segment(lo, hi, iters)
        consider(last)
    if not done.all():
        out[~done] = l2n(last)[~done]
    return (out, done.copy()) if return_feasible else out


def sign_violations(H: np.ndarray, bits: np.ndarray, X: np.ndarray) -> float:
    """Fraction of stored sign bits that directions X contradict."""
    return float(np.mean(((X @ H) > 0).astype(np.uint8) != bits))


class NearestPublic(Attacker):
    """No learning: score the template against public train speaker centroids
    with the protection's own scorer and average the raw centroids of the top
    k. Works for any protection that keeps verification utility."""

    def __init__(self, protection: Protection, gallery_raw: np.ndarray, k: int = 10):
        self.protection = protection
        self.gallery_raw = l2n(gallery_raw)
        self.k = k
        self.name = f"knn{k}"
        self.gallery_probe = protection.probe(self.gallery_raw)

    def invert_templates(self, T: np.ndarray) -> np.ndarray:
        S = self.protection.score(T, self.gallery_probe)
        top = np.argsort(-S, axis=1)[:, : self.k]
        return l2n(self.gallery_raw[top].mean(axis=1))


@dataclass
class PseudoProfiles:
    """Train pseudo-profiles: raw centroids, their utterance index sets, owners."""

    C: np.ndarray  # [P, D] normalised means
    members: list[np.ndarray]  # row indices into the train embedding matrix
    speaker: np.ndarray  # [P]


def sample_pseudo_profiles(X: np.ndarray, y: np.ndarray, per_speaker: int, ks: tuple[int, ...],
                           seed: int) -> PseudoProfiles:
    """`per_speaker` profiles per speaker, each the mean of k random utterances
    of that speaker, k drawn uniformly from `ks` (capped by availability)."""
    rng = np.random.default_rng([seed, 0x9F])
    C, members, owners = [], [], []
    for spk in np.unique(y):
        rows = np.flatnonzero(y == spk)
        for _ in range(per_speaker):
            k = min(int(rng.choice(ks)), len(rows))
            pick = np.sort(rng.choice(rows, k, replace=False))
            members.append(pick)
            C.append(l2n(X[pick].mean(0)))
            owners.append(spk)
    return PseudoProfiles(np.stack(C), members, np.asarray(owners))


def split_speakers(speakers: np.ndarray, frac_val: float, seed: int) -> tuple[np.ndarray, np.ndarray]:
    """Disjoint train/validation speaker sets (validation for attacker selection)."""
    u = np.unique(speakers)
    rng = np.random.default_rng([seed, 0x5A])
    val = np.sort(rng.choice(u, max(1, int(round(frac_val * u.size))), replace=False))
    return np.setdiff1d(u, val), val
