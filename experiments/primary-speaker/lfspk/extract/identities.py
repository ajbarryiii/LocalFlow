"""Comparison of stored and current identity records (render, calibration, training).

Every field must be equal except the nested `w0.w0_commit`, which is recorded
but never compared. It is the last commit touching any file under
lfspk/harness, so a docs-only commit there would otherwise invalidate
renders whose mixer code and corpus indexes are unchanged (w5-stage0-asr,
2026-10-23). W0's mixer code closure (`w0.w0_code_sha256`) and its corpus
index hashes (`w0.w0_index_hashes`) stay compared. Stored records are never
rewritten.
"""

from __future__ import annotations

import copy
from typing import Any, Mapping

RECORDED_NOT_COMPARED = (("w0", "w0_commit"),)


def comparable(ident: Mapping[str, Any]) -> dict:
    out = copy.deepcopy(dict(ident))
    for outer, inner in RECORDED_NOT_COMPARED:
        if isinstance(out.get(outer), dict):
            out[outer].pop(inner, None)
    return out


def same(stored: Mapping[str, Any], current: Mapping[str, Any]) -> bool:
    return comparable(stored) == comparable(current)


def differing(stored: Mapping[str, Any], current: Mapping[str, Any]) -> list[str]:
    """Compared fields that differ (dotted for the nested w0 record)."""
    a, b = comparable(stored), comparable(current)
    out = []
    for k in sorted(set(a) | set(b)):
        if a.get(k) != b.get(k):
            if isinstance(a.get(k), dict) and isinstance(b.get(k), dict):
                out += [f"{k}.{j}" for j in sorted(set(a[k]) | set(b[k])) if a[k].get(j) != b[k].get(j)]
            else:
                out.append(k)
    return out
