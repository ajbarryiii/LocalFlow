"""Keeps smoke runs out of W2's production artifacts (resolved paths, not spelling).

Threat model: accidental mixing of smoke and production data. Deliberately
planted symlinks inside our own artifact tree are out of scope (stage2-r4,
orchestrator decision); every entry point validates all inputs before it
creates or removes any output."""

from __future__ import annotations

import os
from pathlib import Path

REAL_ART = Path("/mnt/hd/localflow-speaker")
PRODUCTION = ("feats", "verify", "frames", "closedset")


def production_dirs() -> list[Path]:
    return [(REAL_ART / "runs" / "W2" / name).resolve() for name in PRODUCTION]


def in_production(path: Path | str) -> bool:
    """True if `path` resolves to, inside, or above a W2 production output directory."""
    p = Path(path).resolve()
    return any(p == d or d in p.parents or p in d.parents for d in production_dirs())


def smoke_env() -> bool:
    return os.environ.get("LFSPK_W2_SMOKE") == "1"


def require_scratch(path: Path | str, what: str) -> None:
    """Smoke inputs and outputs must live outside production (and the env flag must be set)."""
    if not smoke_env():
        raise ValueError(f"{what}: smoke data needs LFSPK_W2_SMOKE=1")
    if in_production(path):
        raise ValueError(f"{what}: {Path(path).resolve()} is inside W2's production artifacts")


def check_inputs(metas: list[dict], smoke: bool, out: Path | str, what: str) -> None:
    """Content check of every input feature set (train and dev): a smoke
    extraction (meta `limit`) is refused unless `smoke` is set explicitly, and
    then `out` must be outside production. Call before creating or removing
    any output."""
    if any(m.get("limit") for m in metas):
        if not smoke:
            raise ValueError(f"{what}: smoke feature sets among the inputs need --smoke")
        require_scratch(out, what)
