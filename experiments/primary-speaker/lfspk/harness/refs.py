"""ASR worklists and scorer-independent word records of a frozen set (DESIGN.md section 7).

    ./python -m lfspk.harness.refs worklist --set dev-v1       # -> ASR_DIR/<set>/worklist.jsonl
    ./python-nemo -m lfspk.harness.asr run ASR_DIR/<set>/worklist.jsonl ASR_DIR/<set>/asr.jsonl
    ./python -m lfspk.harness.refs build --set dev-v1          # -> ASR_DIR/<set>/words.jsonl

ASR keys: `mix:<id>` (the mixture), `tdry:<id>` (placed dry target track),
`idry:<id>:<k>` (placed dry speech track of interferer k), `utt:<utterance id>`
(dry LibriSpeech utterances, for the WER sanity check; worklist `--utts`).

A word record holds, per hypothesis token of the mixture: its frame span, its
attribution (target / interferer / other and C/S/I), its op in the
time-constrained alignment against the target reference (C/S/I) and its region
(single / overlap); per mixture the target deletions and reference counts per
region. Any keep/drop mask then gives every metric by counting.
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Any, Sequence

import numpy as np

from .. import paths
from .align import DEL, INS, MATCH, SUB, Word, align, attribute, decision_span, error_counts, frame_span, normalize, tokens_from_words, transfer_times, word_region
from .asr import read_cache
from .frozen import FrozenSet

ASR_DIR = paths.DATA / "harness" / "asr"


def worklist(fs: FrozenSet) -> list[dict[str, str]]:
    out = []
    for row in fs.manifest:
        f = row["files"]
        out.append({"key": f"mix:{row['id']}", "path": str(fs.root / f["mix"])})
        out.append({"key": f"tdry:{row['id']}", "path": str(fs.root / f["target_dry"])})
        for k, p in enumerate(f["interferers_dry"]):
            out.append({"key": f"idry:{row['id']}:{k}", "path": str(fs.root / p)})
    return out


def utterance_worklist(split: str) -> list[dict[str, str]]:
    from .corpora import Corpus

    c = Corpus(split)
    return [{"key": f"utt:{u.id}", "path": str(u.path)} for s in c.speakers for u in c.utterances[s]]


def _words(asr: dict[str, Any], key: str) -> list[Word]:
    return tokens_from_words([tuple(w) for w in asr[key]["words"]])


def placed_words(corpus, placements: Sequence[Sequence[Any]], n_frames: int, min_inside: float = 0.5) -> list[Word]:
    """True reference words of a placed source on the mixture timeline, from the
    utterances' forced alignments: a word counts if at least `min_inside` of its
    aligned interval lies inside the placed slice and inside the mixture."""
    out: list[Word] = []
    T = n_frames * 10  # integer milliseconds throughout (eval r1 #5)
    for uid, s, e, off in placements:
        lo, hi, shift = s * 10, e * 10, (off - s) * 10
        for w, ws, we in corpus.alignment(uid) or []:
            ws_ms, we_ms = int(round(ws * 1000)), int(round(we * 1000))
            a2 = max(max(ws_ms, lo) + shift, 0)
            b2 = min(min(we_ms, hi) + shift, T)
            dur = max(we_ms - ws_ms, 1)
            if b2 - a2 > 0 and (b2 - a2) * 1000 >= int(round(min_inside * 1000)) * dur:
                for tok in normalize(w):
                    out.append(Word(tok, (ws_ms + shift) / 1000.0, (we_ms + shift) / 1000.0))
    out.sort(key=lambda w: w.start)
    return out


def mixture_record(row: dict[str, Any], labels: np.ndarray, target_active: np.ndarray, asr: dict[str, Any], corpus=None) -> dict[str, Any]:
    """Word record of one mixture. With `corpus` (forced alignments available),
    the target reference and the interferer references are the true transcript
    words with aligned times; otherwise (synthetic tests) the target times come
    from Parakeet on the dry target track and the interferer references are
    Parakeet transcripts of the dry interferer tracks (pseudo-references)."""
    mid = row["id"]
    F = labels.size
    hyp = _words(asr, f"mix:{mid}")
    pseudo = [_words(asr, f"idry:{mid}:{k}") for k in range(len(row["files"]["interferers_dry"]))]
    if corpus is not None:
        target_ref = placed_words(corpus, row["meta"]["target"]["placements"], F, min_inside=0.0)
        int_refs = [placed_words(corpus, it["placements"], F) for it in row["meta"]["interferers"]]
    else:
        tdry = _words(asr, f"tdry:{mid}")
        act = np.flatnonzero(target_active)
        fallback = (act[0] / 100.0, (act[-1] + 1) / 100.0) if act.size else (0.0, F / 100.0)
        target_ref = transfer_times(normalize(row["meta"]["target"]["text"]), tdry, fallback)
        int_refs = pseudo
    att = attribute(hyp, target_ref, int_refs, labels)
    att_pseudo = attribute(hyp, target_ref, pseudo, labels) if corpus is not None else att
    ops = align(hyp, target_ref, timed=True)
    ref_region = [word_region(w, labels) for w in target_ref]
    tok_op = ["I"] * len(hyp)
    tok_region = [word_region(w, labels) for w in hyp]
    op_region = list(tok_region)
    dels = {"single": 0, "overlap": 0}
    for op, i, j in ops:
        if op in (MATCH, SUB):
            tok_op[i] = op
            op_region[i] = ref_region[j]
        elif op == DEL:
            dels[ref_region[j]] += 1
    n_ref = {"single": ref_region.count("single"), "overlap": ref_region.count("overlap")}
    tokens = []
    for i, (w, a) in enumerate(zip(hyp, att)):
        f0, f1 = decision_span(w.start, w.end, F)  # the contract's word frames (80 ms widening)
        tokens.append([w.text, f0, f1, w.parent, a.source, a.kind, a.interferer, tok_op[i], op_region[i], tok_region[i], round(w.start, 3), round(w.end, 3), a.ambiguous])
    untimed = align(hyp, target_ref, timed=False)
    ut = {"S": 0, "D": 0, "I": 0}
    for op, _, _ in untimed:
        if op in ut:
            ut[op] += 1
    # Target dropout (an ASR failure, reported apart from filtering): Parakeet
    # loses more than half of the target words while the dry target alone
    # transcribes with WER <= 10 %.
    ref_tok = [Word(t, 0, 0) for t in normalize(row["meta"]["target"]["text"])]
    dry_tok = [Word(w.text, 0, 0) for w in _words(asr, f"tdry:{mid}")]
    e = error_counts(align(dry_tok, ref_tok, timed=False))
    dry_wer = (e["S"] + e["D"] + e["I"]) / max(1, len(ref_tok))
    lost = (ut["S"] + ut["D"]) / max(1, len(target_ref))
    dropout = bool(lost > 0.5 and dry_wer <= 0.1)
    return {
        "id": mid, "frames": F, "tokens": tokens, "n_ref": n_ref, "dels": dels, "untimed_errors": ut,
        "target_ref": [[w.text, round(w.start, 3), round(w.end, 3)] for w in target_ref],
        "n_interferer_ref": [len(r) for r in int_refs],
        "dropout": dropout, "dry_target_wer": dry_wer,
        # Cross-check: attribution with Parakeet pseudo-references of the dry interferer tracks.
        "attribution_agreement_pseudo": float(np.mean([a.source == b.source for a, b in zip(att, att_pseudo)])) if att else 1.0,
    }


TOKEN_FIELDS = ("text", "f0", "f1", "parent", "source", "kind", "interferer", "target_op", "op_region", "region", "start", "end", "ambiguous")


def build(set_id: str) -> Path:
    from .corpora import Corpus

    fs = FrozenSet(set_id)
    d = ASR_DIR / set_id
    asr = read_cache(d / "asr.jsonl")
    corpus = Corpus(fs.manifest[0]["meta"]["split"])
    out = d / "words.jsonl"
    tmp = out.with_suffix(".tmp")
    with open(tmp, "w") as f:
        for row in fs.manifest:
            lab = fs.labels(row)
            f.write(json.dumps(mixture_record(row, lab["labels"], lab["target_active"], asr, corpus)) + "\n")
    tmp.rename(out)
    return out


def read_words(set_id: str) -> dict[str, dict[str, Any]]:
    out = {}
    for line in (ASR_DIR / set_id / "words.jsonl").read_text().splitlines():
        if line.strip():
            r = json.loads(line)
            out[r["id"]] = r
    return out


def main(argv: list[str] | None = None) -> None:
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    w = sub.add_parser("worklist")
    w.add_argument("--set", required=True)
    w.add_argument("--utts", default=None, help="also add dry utterances of this split (dev only)")
    b = sub.add_parser("build")
    b.add_argument("--set", required=True)
    a = ap.parse_args(argv)
    paths.require_mount()
    if a.cmd == "worklist":
        fs = FrozenSet(a.set)
        items = worklist(fs)
        if a.utts:
            if a.utts != "dev":
                raise SystemExit("dry utterance transcription is for the dev split only")
            items += utterance_worklist(a.utts)
        d = ASR_DIR / a.set
        d.mkdir(parents=True, exist_ok=True)
        (d / "worklist.jsonl").write_text("".join(json.dumps(i) + "\n" for i in items))
        print(f"{len(items)} items -> {d / 'worklist.jsonl'}")
    else:
        print(build(a.set))


if __name__ == "__main__":
    sys.exit(main())
