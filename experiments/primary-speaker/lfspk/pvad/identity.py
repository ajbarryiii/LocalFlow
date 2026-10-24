"""Immutable identity records for resumable artifacts (bank shards, training
checkpoints). An artifact is reused or resumed only if its stored identity
equals the current one; anything else is refused, never merged.

Identity of code is a content hash of the Python sources (so uncommitted edits
count), with the git commit recorded alongside for reference.
"""

from __future__ import annotations

import hashlib
import json
import subprocess
from pathlib import Path
from typing import Any, Iterable, Mapping

REPO = Path(__file__).resolve().parents[2]


def code_sha256(directory: Path, pattern: str = "*.py") -> str:
    """sha256 over "<relative path> <file sha256>" lines of every matching file, sorted."""
    lines = []
    for p in sorted(directory.rglob(pattern)):
        if "__pycache__" in p.parts:
            continue
        lines.append(f"{p.relative_to(directory)} {hashlib.sha256(p.read_bytes()).hexdigest()}")
    return hashlib.sha256(("\n".join(lines) + "\n").encode()).hexdigest()


def _git(*args: str) -> str:
    try:
        return subprocess.run(["git", "-C", str(REPO), *args], capture_output=True, text=True, timeout=20).stdout.strip()
    except Exception:  # noqa: BLE001
        return ""


_MIXER_MODULES: list[Path] | None = None


def mixer_modules() -> list[Path]:
    """Source files of every lfspk.harness module the mixer imports (transitively),
    so edits to W0's evaluator or reports do not invalidate rendered artifacts.
    Computed in a fresh interpreter, so it does not depend on what this process
    happened to import."""
    global _MIXER_MODULES
    if _MIXER_MODULES is None:
        import sys

        code = ("import json, sys; import lfspk.harness.mix; print(json.dumps(sorted({m.__file__ for n, m in "
                "list(sys.modules.items()) if (n == 'lfspk.harness' or n.startswith('lfspk.harness.')) "
                "and getattr(m, '__file__', None)})))")
        out = subprocess.run([sys.executable, "-c", code], capture_output=True, text=True, timeout=300, cwd=str(REPO),
                             check=True).stdout.strip().splitlines()[-1]
        _MIXER_MODULES = sorted({Path(f).resolve() for f in json.loads(out)})
    return list(_MIXER_MODULES)


def files_sha256(files: Iterable[Path], root: Path) -> str:
    lines = [f"{p.relative_to(root)} {hashlib.sha256(p.read_bytes()).hexdigest()}" for p in sorted(files)]
    return hashlib.sha256(("\n".join(lines) + "\n").encode()).hexdigest()


def w0_identity(split: str = "train") -> dict[str, Any]:
    """W0's mixer code (the modules the mixer imports) and corpus indexes, as they would render now."""
    from lfspk.harness.corpora import Corpus

    mods = mixer_modules()
    return {
        "w0_code_sha256": files_sha256(mods, REPO),
        "w0_code_files": [str(p.relative_to(REPO)) for p in mods],
        "w0_commit": _git("log", "-1", "--format=%H", "--", "lfspk/harness"),
        "w0_index_hashes": Corpus(split).index_hashes(),
    }


def w3_code_identity() -> dict[str, Any]:
    return {"w3_code_sha256": code_sha256(REPO / "lfspk" / "pvad"), "repo_head": _git("rev-parse", "HEAD")}


def canonical(record: Mapping[str, Any]) -> str:
    return json.dumps(record, sort_keys=True, separators=(",", ":"))


def mismatches(stored: Mapping[str, Any], current: Mapping[str, Any], ignore: Iterable[str] = ()) -> list[str]:
    """Keys whose values differ (or exist on one side only), except `ignore`."""
    skip = set(ignore)
    keys = (set(stored) | set(current)) - skip
    return sorted(k for k in keys if canonical({"v": stored.get(k)}) != canonical({"v": current.get(k)}))


def require_same(stored: Mapping[str, Any], current: Mapping[str, Any], what: str, ignore: Iterable[str] = ()) -> None:
    bad = mismatches(stored, current, ignore)
    if bad:
        raise ValueError(f"refusing to reuse {what}: identity differs in {bad}")
