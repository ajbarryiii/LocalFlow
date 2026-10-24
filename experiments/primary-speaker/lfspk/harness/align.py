"""Text normalisation, time-constrained alignment and word attribution (DESIGN.md section 7).

A Word is a normalised token with a time span in seconds on the mixture
timeline. Hypothesis words that normalise to several tokens (hyphens, numbers)
give each token the parent word's span; their keep/drop decision is then
identical because the rule averages scores over the same frames.
"""

from __future__ import annotations

import re
import unicodedata
from dataclasses import dataclass
from typing import Sequence

import numpy as np

from ..api import FRAME_SAMPLES, SAMPLE_RATE

# Time tolerance for pairing a hypothesis word with a reference word. 0.5 s
# after dev-v1 showed 0.2 s splits correct words (Parakeet TDT timestamps vs CTC
# reference times): S0 timed WER 3.89 % at 0.2 s, 3.07 % at 0.5 s = untimed.
TOLERANCE_S = 0.5
# The contract's decision rule (amended 2026-10-21): a word's frames are its
# Parakeet span widened by 80 ms on each side (one encoder frame), clipped to
# the recording. Used only through decision_span, for every scorer and the oracle.
WORD_WIDEN_S = 0.08
FRAME_S = FRAME_SAMPLES / SAMPLE_RATE

# --- normalisation ------------------------------------------------------------------

_ONES = "zero one two three four five six seven eight nine ten eleven twelve thirteen fourteen fifteen sixteen seventeen eighteen nineteen".split()
_TENS = "_ _ twenty thirty forty fifty sixty seventy eighty ninety".split()
_ORD = {"one": "first", "two": "second", "three": "third", "five": "fifth", "eight": "eighth", "nine": "ninth", "twelve": "twelfth"}


def _below_1000(n: int) -> list[str]:
    out: list[str] = []
    if n >= 100:
        out += [_ONES[n // 100], "hundred"]
        n %= 100
        if n:
            out.append("and")
    if n >= 20:
        out.append(_TENS[n // 10])
        if n % 10:
            out.append(_ONES[n % 10])
    elif n or not out:
        out.append(_ONES[n])
    return out


def number_words(n: int) -> list[str]:
    """Cardinal in British/LibriSpeech style ("one hundred and five")."""
    if n < 0:
        return ["minus"] + number_words(-n)
    if n < 1000:
        return _below_1000(n)
    out: list[str] = []
    for scale, name in ((10**9, "billion"), (10**6, "million"), (1000, "thousand")):
        if n >= scale:
            out += _below_1000(n // scale) + [name]
            n %= scale
    if n:
        if n < 100:
            out.append("and")
        out += _below_1000(n)
    return out


def _digits_to_words(tok: str) -> list[str]:
    m = re.fullmatch(r"(\d+)(st|nd|rd|th)?", tok)
    if not m:
        return [tok]
    n = int(m.group(1))
    if 1100 <= n <= 1999 and not m.group(2) and n % 100 != 0:
        words = _below_1000(n // 100) + _below_1000(n % 100) if n % 100 >= 10 else _below_1000(n // 100) + ["o"] + _below_1000(n % 100)
    else:
        words = number_words(n)
    if m.group(2):
        last = words[-1]
        words[-1] = _ORD.get(last, last[:-1] + "ieth" if last.endswith("y") else last + "th")
    return words


def normalize(text: str) -> list[str]:
    """Tokens for scoring: ASCII, lower case, hyphens split, digits spelled out."""
    t = unicodedata.normalize("NFKD", text).encode("ascii", "ignore").decode().lower()
    t = re.sub(r"(?<=\d),(?=\d{3})", "", t)
    t = t.replace("%", " percent ").replace("&", " and ")
    t = re.sub(r"(\d)\.(\d)", r"\1 point \2", t)
    t = re.sub(r"[-/]", " ", t)
    t = re.sub(r"[^a-z0-9' ]", " ", t)
    out: list[str] = []
    for tok in t.split():
        tok = tok.strip("'")
        if not tok:
            continue
        out += _digits_to_words(tok) if any(c.isdigit() for c in tok) else [tok]
    return out


# --- words -------------------------------------------------------------------------------


@dataclass(frozen=True)
class Word:
    text: str
    start: float
    end: float
    parent: int = -1  # index of the hypothesis word it came from (-1 for references)


def tokens_from_words(words: Sequence[tuple[str, float, float]]) -> list[Word]:
    """Normalise timed hypothesis words; tokens inherit their word's span."""
    out: list[Word] = []
    for i, (w, s, e) in enumerate(words):
        for tok in normalize(w):
            out.append(Word(tok, float(s), float(max(e, s)), i))
    return out


def decision_span(start: float, end: float, n_frames: int, widen_s: float = WORD_WIDEN_S) -> tuple[int, int]:
    """Frames [f0, f1) whose mean score decides a word: the span widened by
    widen_s on each side, clipped to the recording (contract rule)."""
    return frame_span(max(0.0, start - widen_s), end + widen_s, n_frames)


def frame_span(start: float, end: float, n_frames: int) -> tuple[int, int]:
    """Frames [f0, f1) covering [start, end] seconds: floor(start/10 ms) to
    ceil(end/10 ms), at least one frame, clipped to the timeline."""
    f0 = int(np.floor(start / FRAME_S + 1e-9))
    f1 = int(np.ceil(end / FRAME_S - 1e-9))
    f0 = min(max(f0, 0), max(n_frames - 1, 0))
    f1 = min(max(f1, f0 + 1), n_frames)
    return f0, f1


# --- alignment ---------------------------------------------------------------------------

MATCH, SUB, DEL, INS = "C", "S", "D", "I"


def compatible(h: Word, r: Word, tol: float = TOLERANCE_S) -> bool:
    return (h.start - tol) <= r.end and r.start <= (h.end + tol)


def align(hyp: Sequence[Word], ref: Sequence[Word], timed: bool = True, tol: float = TOLERANCE_S) -> list[tuple[str, int, int]]:
    """Minimum-edit alignment of hyp against ref as (op, hyp index, ref index),
    -1 for the missing side. With `timed`, a pair may be matched or substituted
    only if time-compatible. Lexicographic cost (eval r5): fewest edits first,
    then most exact matches, then the smallest summed start-time difference of
    the paired words (integer ms, capped), so a repeated word pairs with its
    temporally closest occurrence; remaining ties prefer C > S > D > I when
    tracing back. Edit counts (WER) are those of a minimum-edit alignment."""
    H, R = len(hyp), len(ref)
    N = max(H, R) + 1
    CAP = 10_000  # ms; per-pair time term
    M_ = N * CAP + 1  # one exact match outweighs every possible time term
    E = N * (M_ + CAP) + 1  # one edit outweighs every match bonus and time term
    assert N * E < (1 << 62), "alignment too long for the integer cost"
    INF = 1 << 62
    D = np.full((H + 1, R + 1), INF, dtype=np.int64)
    D[0, :] = np.arange(R + 1) * E
    D[:, 0] = np.arange(H + 1) * E
    ht = [w.text for w in hyp]
    rt = [w.text for w in ref]

    def diag(i: int, j: int) -> int | None:
        if timed and not compatible(hyp[i - 1], ref[j - 1], tol):
            return None
        dt = min(CAP, int(round(abs(hyp[i - 1].start - ref[j - 1].start) * 1000))) if timed else 0
        return (-M_ if ht[i - 1] == rt[j - 1] else E) + dt

    for i in range(1, H + 1):
        Di, Dp = D[i], D[i - 1]
        for j in range(1, R + 1):
            best = min(Dp[j] + E, Di[j - 1] + E)  # insertion, deletion
            c = diag(i, j)
            if c is not None and Dp[j - 1] + c < best:
                best = Dp[j - 1] + c
            Di[j] = best
    ops: list[tuple[str, int, int]] = []
    i, j = H, R
    while i > 0 or j > 0:
        if i > 0 and j > 0:
            c = diag(i, j)
            if c is not None and D[i, j] == D[i - 1, j - 1] + c:
                ops.append((MATCH if ht[i - 1] == rt[j - 1] else SUB, i - 1, j - 1))
                i, j = i - 1, j - 1
                continue
        if j > 0 and D[i, j] == D[i, j - 1] + E:
            ops.append((DEL, -1, j - 1))
            j -= 1
            continue
        ops.append((INS, i - 1, -1))
        i -= 1
    ops.reverse()
    return ops


def error_counts(ops: Sequence[tuple[str, int, int]]) -> dict[str, int]:
    c = {MATCH: 0, SUB: 0, DEL: 0, INS: 0}
    for op, _, _ in ops:
        c[op] += 1
    return c


def transfer_times(ref_tokens: Sequence[str], hyp: Sequence[Word], fallback: tuple[float, float]) -> list[Word]:
    """Reference words with times taken from an untimed alignment to a timed
    hypothesis of the same (clean) audio. Matched or substituted words copy the
    hypothesis span; deleted words are interpolated between neighbours."""
    ref = [Word(t, 0.0, 0.0) for t in ref_tokens]
    ops = align(hyp, ref, timed=False)
    spans: list[tuple[float, float] | None] = [None] * len(ref)
    for op, i, j in ops:
        if op in (MATCH, SUB):
            spans[j] = (hyp[i].start, hyp[i].end)
    known = [k for k, s in enumerate(spans) if s is not None]
    if not known:
        lo, hi = fallback
        n = max(1, len(ref))
        return [Word(r.text, lo + (hi - lo) * k / n, lo + (hi - lo) * (k + 1) / n) for k, r in enumerate(ref)]
    out: list[Word] = []
    for k, r in enumerate(ref):
        if spans[k] is not None:
            s, e = spans[k]
        else:
            prev = max((q for q in known if q < k), default=None)
            nxt = min((q for q in known if q > k), default=None)
            s = spans[prev][1] if prev is not None else fallback[0]
            e = spans[nxt][0] if nxt is not None else fallback[1]
            # Spread consecutive deleted words over the gap.
            run_lo = (prev + 1) if prev is not None else 0
            run_hi = nxt if nxt is not None else len(ref)
            n = run_hi - run_lo
            pos = k - run_lo
            if e < s:
                e = s
            s, e = s + (e - s) * pos / n, s + (e - s) * (pos + 1) / n
        out.append(Word(r.text, float(s), float(e)))
    return out


# --- attribution ----------------------------------------------------------------------------

TARGET, INTERFERER, OTHER = "target", "interferer", "other"


@dataclass(frozen=True)
class Attribution:
    source: str  # TARGET, INTERFERER or OTHER
    kind: str  # C, S or I (I = unaligned, attributed by frame labels)
    interferer: int = -1  # which interferer, for INTERFERER
    ambiguous: bool = False  # exact match to the target and to an interferer (eval r1 #6)


def _overlap(a: Word, b: Word) -> float:
    return max(0.0, min(a.end, b.end) - max(a.start, b.start))


def attribute(hyp: Sequence[Word], target_ref: Sequence[Word], interferer_refs: Sequence[Sequence[Word]], labels: np.ndarray, tol: float = TOLERANCE_S) -> list[Attribution]:
    """Attribute each hypothesis token to the target, an interferer, or neither.

    1. Per source, a time-constrained alignment of the whole hypothesis
       against that source's reference.
    2. An exact match wins over a substitution; between sources of the same
       kind, the larger time overlap with the aligned reference word, then the
       target.
    3. Unaligned tokens go by frame labels over their span: majority label 2 ->
       interferer; majority target-active (1 or 3) -> target insertion; else other.
    """
    refs = [target_ref, *interferer_refs]
    cand: list[list[tuple[int, int, float, int]]] = [[] for _ in hyp]  # (rank, -source order, overlap, source)
    for s, ref in enumerate(refs):
        for op, i, j in align(hyp, ref, timed=True, tol=tol):
            if op in (MATCH, SUB):
                cand[i].append((1 if op == MATCH else 0, _overlap(hyp[i], ref[j]), -s, s))
    out: list[Attribution] = []
    n = labels.size
    for i, h in enumerate(hyp):
        if cand[i]:
            rank, _, _, s = max(cand[i])
            kind = MATCH if rank == 1 else SUB
            exact = {c[3] for c in cand[i] if c[0] == 1}
            amb = 0 in exact and any(x > 0 for x in exact)
            out.append(Attribution(TARGET, kind, -1, amb) if s == 0 else Attribution(INTERFERER, kind, s - 1, amb))
            continue
        f0, f1 = frame_span(h.start, h.end, n)
        lab = labels[f0:f1]
        if lab.size and np.mean(lab == 2) > 0.5:
            # The interferer active over most of the span; which one is not
            # needed by any metric, so the first is reported.
            out.append(Attribution(INTERFERER, INS, 0))
        elif lab.size and np.mean((lab == 1) | (lab == 3)) > 0.5:
            out.append(Attribution(TARGET, INS))
        else:
            out.append(Attribution(OTHER, INS))
    return out


def word_region(w: Word, labels: np.ndarray) -> str:
    """'overlap' if at least half of the word's frames carry label 3."""
    f0, f1 = frame_span(w.start, w.end, labels.size)
    lab = labels[f0:f1]
    return "overlap" if lab.size and np.mean(lab == 3) >= 0.5 else "single"
