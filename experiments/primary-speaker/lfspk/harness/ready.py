"""Write the harness READY.json (DESIGN.md section 9).

    ./python -m lfspk.harness.ready --dev dev-v1 --test test-v1

Records the frozen scenario set ids and content hashes, the ASR cache identity,
the evaluate and apply commands and the scorer factory convention. Other
workstreams wait on this file. Test-set facts are hashes and counts only.
"""

from __future__ import annotations

import argparse
import json
import sys
import time

from .. import paths
from .frozen import SETS_DIR, FrozenSet, content_hash
from .refs import ASR_DIR

READY = paths.DATA / "harness" / "READY.json"


def main(argv: list[str] | None = None) -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--dev", required=True)
    ap.add_argument("--test", required=True)
    a = ap.parse_args(argv)
    sets = {}
    for role, sid in (("dev", a.dev), ("test", a.test)):
        fs = FrozenSet(sid)
        recomputed = content_hash(SETS_DIR / sid)  # read-only; hashes bytes, never inspects content
        if recomputed != fs.hash:
            raise SystemExit(f"{sid}: content hash mismatch (frozen set changed since it was frozen)")
        entry = {"set_id": sid, "hash": fs.hash, "mixtures": len(fs.manifest), "speakers": len(fs.plans),
                 "enrollment_dictations": len(fs.enrollment_rows)}
        meta = ASR_DIR / sid / "asr.meta.json"
        if meta.exists():
            entry["asr_identity"] = json.loads(meta.read_text())
        entry["words_ready"] = (ASR_DIR / sid / "words.jsonl").exists()
        sets[role] = entry
    ready = {
        "written_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "sets": sets,
        "scorer_factory": "MODULE:CALLABLE, called once per worker as CALLABLE(**args) with string args from --arg key=value; "
                          "returns an lfspk.api.TargetSpeakerScorer. 'oracle' is built in.",
        "evaluate_dev": f"./python -m lfspk.harness.evaluate run --set {a.dev} --scorer MODULE:CALLABLE [--arg k=v ...] [--half A|B|all] --workers 8",
        "apply_test (orchestrator only)": f"./python -m lfspk.harness.evaluate apply --set {a.test} --scorer MODULE:CALLABLE [--arg k=v ...] --calibration <dev run>/calibration.json",
        "outputs": "runs/W0/eval/<name>/<set>-<half>/ unless --out: results.json, results.md, calibration.json, scores/<speaker>.npz (float32), timing.json",
        "selection": "select on --half A, report on --half B (canonical halves: lfspk.harness.halves.dev_halves)",
    }
    READY.write_text(json.dumps(ready, indent=1))
    print(json.dumps(ready, indent=1))


if __name__ == "__main__":
    sys.exit(main())
