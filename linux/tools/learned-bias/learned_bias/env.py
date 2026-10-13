"""Machine-specific locations come from the environment, never the
repository (AGENTS.md: no identifying filesystem paths):

- `LF_EXP2_ROOT`: the experiment's data and output root W (prep/, train/,
  eval/, fixtures/);
- `LF_EXPORT`: the Parakeet export directory (or its export.safetensors),
  unless `--export` is given;
- `LF_GPU_LOCK`: the fcntl lock file shared by GPU jobs.

Each accessor fails with a clear message when its variable is unset.
"""

import os
from pathlib import Path


class ConfigError(RuntimeError):
    pass


def _get(var, what):
    v = os.environ.get(var)
    if not v:
        raise ConfigError(f"{var} is not set: it must name {what}")
    return v


def exp2_root():
    """W, from LF_EXP2_ROOT."""
    return Path(_get("LF_EXP2_ROOT", "the experiment root W (with prep/, train/, eval/)"))


def export_path(explicit=None):
    """The export, from `explicit` (e.g. --export) or LF_EXPORT."""
    return str(explicit) if explicit else _get("LF_EXPORT", "the Parakeet export directory (or pass --export)")


def gpu_lock(explicit=None):
    """The GPU lock file, from `explicit` or LF_GPU_LOCK."""
    return str(explicit) if explicit else _get("LF_GPU_LOCK", "the shared GPU lock file")


def optional(var):
    """The variable's value, or None (for tests that need real data)."""
    return os.environ.get(var) or None
