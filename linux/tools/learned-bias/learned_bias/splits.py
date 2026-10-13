"""Deterministic call-level splits (shared definitions with the Rust side)."""

import hashlib
import math


def spgi_is_dev(call):
    """SPGISpeech dev split: the first 16 hex digits of sha256(call id) as an
    integer, mod 10 == 0. The call id is the utterance id before "/"."""
    return int(hashlib.sha256(call.encode()).hexdigest()[:16], 16) % 10 == 0


def call_rank(call, seed):
    """A seeded, call-stable rank for nested learning-curve subsets: the
    first fraction of calls by this rank is a subset of every larger one."""
    return hashlib.sha256(f"{seed}:{call}".encode()).hexdigest()


def subset_calls(calls, fraction, seed):
    """The first ceil(fraction * n) distinct calls by `call_rank`. Nested in
    `fraction` for a fixed seed."""
    if not 0.0 < fraction <= 1.0:
        raise ValueError(f"fraction {fraction} must be in (0, 1]")
    calls = sorted(set(calls))
    k = math.ceil(fraction * len(calls) - 1e-9)
    return set(sorted(calls, key=lambda c: call_rank(c, seed))[:k])
