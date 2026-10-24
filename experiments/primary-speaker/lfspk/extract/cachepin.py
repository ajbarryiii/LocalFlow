"""Pinning of bypass entries to the source B cache, and the front-end ASR cache
identity (DESIGN section 10.2; review rounds r3 #1, r4 #1, r4 #2).

A bypassed recording is never re-transcribed: its entry in a front end's ASR
cache is B's cached record, copied and flagged `bypass`, and pinned to
- B's cache identity hash (the SHA-256 of B's `.meta.json` identity: model,
  model hash, decoding, NeMo version),
- B's key and audio SHA-256 (which must equal the frozen set's hash), and
- `record_digest` of B's record.
Every load re-validates every copied entry against the current B cache; a
missing record, a changed record digest or a changed B identity raises
`StaleCache`. There is no silent fallback.

Batching mode is part of every front-end ASR cache identity: `batched` for
headline artefacts, `single` only for the exploratory batch-1 replay, which a
headline load refuses.
"""

from __future__ import annotations

import hashlib
import json
from typing import Any, Mapping

RECORD_FIELDS = ("key", "audio_sha256", "text", "words")
BATCHING_MODES = ("batched", "single")


class StaleCache(RuntimeError):
    """A front-end cache no longer matches its source B cache."""


def _canonical(obj: Any) -> bytes:
    return json.dumps(obj, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode("utf-8")


def record_digest(record: Mapping[str, Any]) -> str:
    """SHA-256 of exactly key, audio_sha256, text and the ordered words of a
    cache record, as the cache's JSONL parser returns it: deterministic JSON
    (sorted keys, fixed separators, UTF-8), floats by Python's shortest
    round-trip repr, no rounding, no normalisation, no other field."""
    missing = [k for k in RECORD_FIELDS if k not in record]
    if missing:
        raise KeyError(f"record lacks {missing}")
    return hashlib.sha256(_canonical({k: record[k] for k in RECORD_FIELDS})).hexdigest()


def identity_hash(identity: Mapping[str, Any]) -> str:
    """SHA-256 of an identity dict in the same canonical JSON."""
    return hashlib.sha256(_canonical(dict(identity))).hexdigest()


def pin_bypass(b_record: Mapping[str, Any], b_identity: Mapping[str, Any], frozen_audio_sha256: str) -> dict[str, Any]:
    """The front-end cache entry for a bypassed recording: B's record, flagged
    and pinned."""
    if b_record["audio_sha256"] != frozen_audio_sha256:
        raise StaleCache(f"{b_record['key']}: B's audio hash differs from the frozen set's")
    entry = {k: b_record[k] for k in RECORD_FIELDS}
    entry.update(bypass=True, b_record_digest=record_digest(b_record), b_identity_hash=identity_hash(b_identity))
    return entry


def verify_bypass(entries: Mapping[str, Mapping[str, Any]], b_records: Mapping[str, Mapping[str, Any]],
                  b_identity: Mapping[str, Any], frozen_audio_sha256: Mapping[str, str]) -> int:
    """Re-validate every bypass entry of a front-end cache against the current
    B cache. Returns the number checked; raises StaleCache on any mismatch."""
    bid = identity_hash(b_identity)
    n = 0
    for key, e in entries.items():
        if not e.get("bypass"):
            continue
        n += 1
        if e.get("b_identity_hash") != bid:
            raise StaleCache(f"{key}: B's cache identity changed since this entry was copied")
        rec = b_records.get(key)
        if rec is None:
            raise StaleCache(f"{key}: no longer in the B cache")
        if record_digest(rec) != e.get("b_record_digest"):
            raise StaleCache(f"{key}: B's record changed since it was copied")
        if record_digest(e) != e["b_record_digest"]:
            raise StaleCache(f"{key}: the copied entry was altered")
        if rec["audio_sha256"] != frozen_audio_sha256.get(key):
            raise StaleCache(f"{key}: audio hash differs from the frozen set's")
    return n


def frontend_cache_identity(stage_a_identity_hash: str, config: Mapping[str, Any], asr_identity: Mapping[str, Any],
                            b_identity: Mapping[str, Any], hook_code_sha256: str, batching: str,
                            batch_size: int, compared_with: str | None = None) -> dict[str, Any]:
    """Identity of a front-end ASR cache. Stage B's ASR identity must equal B's
    (bypass entries are B's transcripts). `compared_with` (the hash of the
    batched cache) is required for, and only allowed on, the `single` replay."""
    if batching not in BATCHING_MODES:
        raise ValueError(f"batching must be one of {BATCHING_MODES}")
    if dict(asr_identity) != dict(b_identity):
        raise StaleCache("stage B's ASR identity differs from B's cache identity")
    if (batching == "single") != (compared_with is not None):
        raise ValueError("a `single` replay must pin the batched cache it is compared with, and only it may")
    ident = {"kind": "w5-frontend-asr-cache", "stage_a": stage_a_identity_hash, "config": dict(config),
             "asr": dict(asr_identity), "b_identity_hash": identity_hash(b_identity),
             "hook_code_sha256": hook_code_sha256, "batching": batching, "batch_size": int(batch_size)}
    if compared_with is not None:
        ident["compared_with"] = compared_with
    return ident


def require_headline(identity: Mapping[str, Any]) -> None:
    """Loaders of selection, headline and confirmatory artefacts call this."""
    if identity.get("kind") != "w5-frontend-asr-cache":
        raise ValueError("not a W5 front-end ASR cache")
    if identity.get("batching") != "batched":
        raise ValueError(f"headline loads require batching 'batched', got {identity.get('batching')!r}")
