"""The evaluator (DESIGN.md sections 6 and 8).

    ./python -m lfspk.harness.evaluate run --set dev-v1 --scorer MODULE:CALLABLE \
        [--arg key=value ...] [--half all|A|B] [--workers 8] [--out DIR]
    ./python -m lfspk.harness.evaluate run --set dev-v1 --scorer oracle
    ./python -m lfspk.harness.evaluate metrics --out DIR      # recompute from saved scores
    ./python -m lfspk.harness.evaluate latency --set dev-v1 --scorer MODULE:CALLABLE

Scorer factory convention: `MODULE:CALLABLE`, called once per worker process
as CALLABLE(**args) and returning a lfspk.api.TargetSpeakerScorer; args are
strings from `--arg key=value` (the factory parses them). `oracle` is built
in (it reads the frame labels). Output (default RUNS/W0/eval/<scorer name>/<set
id>-<half>/): scores/<speaker>.npz (float16 frame scores per condition and
mixture), timing.json, results.json (machine-readable) and results.md.

Conditions: device in {builtin (matched), headset (mismatched)} x enrollment
{clean, contaminated} x k in {3, 10, 30}. Mixtures are always built-in.
The scorer sees enroll(first 3), then update for each later dictation in order;
scores are taken after 3, 10 and 30 dictations.
"""

from __future__ import annotations

import argparse
import importlib
import json
import os
import subprocess
import sys
import time
from concurrent.futures import ProcessPoolExecutor
from pathlib import Path
from typing import Any

import numpy as np

from .. import paths
from ..api import check_audio, check_scores
from . import metrics as M
from .frozen import FrozenSet
from .refs import read_words

DEVICES = {"builtin": "matched", "headset": "mismatched"}
CONTAM = {False: "clean", True: "contaminated"}
KS = (3, 10, 30)
HEADLINE = ("builtin", False, 10)
HEADLINE_RELATIONS = ("cross_project", "same_project_cross_chapter")
BOOT = 2000
BOOT_SEED = 0
LATENCY_MIXTURES = 30


def cond_key(device: str, contaminated: bool, k: int) -> str:
    return f"{device}|{CONTAM[contaminated]}|{k}"


def load_factory(spec: str):
    mod, _, fn = spec.partition(":")
    if not fn:
        raise SystemExit("scorer must be MODULE:CALLABLE or oracle")
    return getattr(importlib.import_module(mod), fn)


def parse_args_kv(items: list[str]) -> dict[str, str]:
    out = {}
    for it in items:
        k, sep, v = it.partition("=")
        if not sep:
            raise SystemExit(f"--arg needs key=value, got {it!r}")
        out[k] = v
    return out


def involved_speakers(row: dict[str, Any]) -> list[str]:
    """LibriSpeech speakers a mixture involves: target and every interferer."""
    out = [row["speaker"]]
    for it in row["meta"]["interferers"]:
        if it.get("speaker"):
            out.append(str(it["speaker"]))
        for s in it.get("speakers") or []:
            out.append(str(s))
    return out


# --- scoring ---------------------------------------------------------------------------

_SCORER = None


def _scorer(spec: str, kwargs: dict[str, str]):
    global _SCORER
    if _SCORER is None:
        _SCORER = load_factory(spec)(**kwargs)
    return _SCORER


def _score_speaker(args: tuple) -> dict[str, Any]:
    set_id, spec, kwargs, speaker, mixture_ids, out_dir, *rest = args
    fs = FrozenSet(set_id, root=Path(rest[0])) if rest and rest[0] else FrozenSet(set_id)
    rows = {r["id"]: r for r in fs.manifest}
    sc = _scorer(spec, kwargs)
    audios = {mid: check_audio(fs.audio(rows[mid]["files"]["mix"])) for mid in mixture_ids}
    saved: dict[str, np.ndarray] = {}
    timing: dict[str, Any] = {"enroll_s": [], "update_s": [], "score_s": 0.0, "score_audio_s": 0.0, "profile_bytes": {}}

    def score_all(prof, key: str) -> None:
        timing["profile_bytes"][key] = len(prof.to_bytes())
        for mid in mixture_ids:
            a = audios[mid]
            t = time.perf_counter()
            sc_ = check_scores(sc.score(prof, a), a.size)
            timing["score_s"] += time.perf_counter() - t
            timing["score_audio_s"] += a.size / 16000
            saved[f"{key}|{mid}"] = sc_.astype(np.float32)

    for device in DEVICES:
        clean = fs.enrollment_stream(speaker, device, False)
        dirty = fs.enrollment_stream(speaker, device, True)
        first_diff = next((i for i, (c, d) in enumerate(zip(clean, dirty)) if c["file"] != d["file"]), len(clean))
        for contaminated, stream in ((False, clean), (True, dirty)):
            prof, done = None, 0
            for k in KS:
                if len(stream) < k:
                    break
                key = cond_key(device, contaminated, k)
                if contaminated and k <= first_diff:
                    # The first k dictations are the clean ones: same profile, same scores.
                    for mid in mixture_ids:
                        saved[f"{key}|{mid}"] = saved[f"{cond_key(device, False, k)}|{mid}"]
                    continue
                if prof is None:
                    t = time.perf_counter()
                    prof = sc.enroll([check_audio(fs.audio(r["file"])) for r in stream[:3]])
                    timing["enroll_s"].append(time.perf_counter() - t)
                    done = 3
                for r in stream[done:k]:
                    t = time.perf_counter()
                    prof = sc.update(prof, check_audio(fs.audio(r["file"])))
                    timing["update_s"].append(time.perf_counter() - t)
                done = k
                score_all(prof, key)
    save_scores(Path(out_dir) / "scores" / f"{speaker}.npz", saved)
    return {"speaker": speaker, **timing}


def scorer_identity(spec: str, kwargs: dict[str, str], set_id: str, set_hash: str) -> dict[str, Any]:
    import hashlib

    body = {"scorer": spec, "args": dict(sorted(kwargs.items())), "set_id": set_id, "set_hash": set_hash}
    body["hash"] = hashlib.sha256(json.dumps(body, sort_keys=True).encode()).hexdigest()
    return body


# --- score content identity (code + the files the scorer loads) ------------------------------------
# The score identity above names the factory, its argument strings and the set. A content identity
# (scores/CONTENT.json) adds what those names do not pin: the scorer's code closure and the bytes of
# every file it reads while it is built and first used (checkpoints, recalibration files, configs).
# Directories combined into one word filter must agree on it (lfspk.harness.frontend_eval.load_filter).

_CONTENT_SCRIPT = r"""
import hashlib, importlib, json, os, sys
spec, kwargs = sys.argv[1], json.loads(sys.argv[2])
sys.path[:] = json.loads(sys.argv[3])  # exactly the caller's import path, as its spawn workers get it
opened = []
def hook(event, args):
    # every open that can read (r, r+, w+, a+, x+; os.open with O_RDONLY or O_RDWR), its path made absolute
    # here, at open time, against this process's working directory (the scoring cwd), without normalising
    # ("a/../b" after a symlink is resolved by the kernel rule later, in walk())
    if event == "open" and args and isinstance(args[0], (str, bytes)):
        mode, flags = args[1], args[2] if len(args) > 2 else 0
        readable = ("r" in mode or "+" in mode) if isinstance(mode, str) else ((flags or 0) & os.O_ACCMODE) != os.O_WRONLY
        if readable:
            p = os.fsdecode(args[0])
            opened.append(p if os.path.isabs(p) else os.path.join(os.getcwd(), p))
sys.addaudithook(hook)
mod, _, fn = spec.partition(":")
sc = getattr(importlib.import_module(mod), fn)(**kwargs)
warm = "ok"
try:
    import numpy as np
    a = (np.random.default_rng(0).standard_normal(48000) * 0.05).astype(np.float32)
    prof = sc.enroll([a, a, a])
    prof = sc.update(prof, a)
    sc.score(prof, a)
except Exception as e:  # the caller refuses an identity whose warm-up failed
    warm = "failed: " + type(e).__name__ + ": " + str(e)[:200]
mods = sorted({m.__file__ if os.path.isabs(m.__file__) else os.path.join(os.getcwd(), m.__file__) for n, m in list(sys.modules.items())
               if (n == "lfspk" or n.startswith("lfspk.") or n == mod or n.startswith(mod.split(".")[0] + ".")) and getattr(m, "__file__", None)})
print(json.dumps({"modules": mods, "opened": sorted(set(opened)), "warmup": warm,
                  "device_env": {"CUDA_VISIBLE_DEVICES": os.environ.get("CUDA_VISIBLE_DEVICES")}}))
"""
_SKIP_PREFIXES = ("/proc", "/sys", "/dev", "/etc", "/usr", "/nix/store", "/run")
_SKIP_SUFFIXES = (".py", ".pyc", ".pyi", ".so", ".pth")


def _sha256_path(p: Path) -> str:
    import hashlib

    h = hashlib.sha256()
    with open(p, "rb") as f:
        for b in iter(lambda: f.read(1 << 20), b""):
            h.update(b)
    return h.hexdigest()


def content_identity(spec: str, kwargs: dict[str, str]) -> dict[str, Any]:
    """The scorer's code closure (its module and every lfspk module imported
    while it is built and warmed up) and every other file it reads meanwhile,
    each with its SHA-256, measured in a fresh interpreter with the environment
    scoring uses: this process's working directory, import paths (sys.path) and
    environment, device variables included (run_scoring's spawn workers inherit
    the same). Paths are kept as opened (absolute, symlinks not resolved; the
    bytes hashed are the target's). Interpreter and library files are excluded.
    A lazy load is captured by the warm-up (enroll, update, score on 3 s of
    synthetic noise); a failed warm-up refuses. Not covered: files opened by
    native code or by subprocesses, outside Python's audit hooks (none of this
    experiment's scorers loads artefacts that way; RESULTS)."""
    import hashlib

    root = Path(__file__).resolve().parents[2]
    from multiprocessing import process as _mpp

    path = list(sys.path)
    if "" in path:  # as multiprocessing's spawn prepares its workers' sys.path
        path[path.index("")] = _mpp.ORIGINAL_DIR
    r = subprocess.run([sys.executable, "-c", _CONTENT_SCRIPT, spec, json.dumps(dict(sorted(kwargs.items()))), json.dumps(path)],
                       cwd=os.getcwd(), env=dict(os.environ), capture_output=True, text=True, timeout=1800)
    if r.returncode != 0:
        raise SystemExit(f"content identity of {spec}: {r.stderr[-1000:]}")
    out = json.loads(r.stdout.strip().splitlines()[-1])
    if out["warmup"] != "ok":
        raise SystemExit(f"content identity of {spec}: the warm-up failed ({out['warmup']}); refusing")
    code = []
    for f in out["modules"]:
        _, real = walk(f)
        # repository modules by relative path; others (e.g. W1's pinned source archives imported as
        # lfspk._vendor.*) by absolute path
        code.append([str(Path(f).relative_to(root)) if Path(f).is_relative_to(root) else f, _sha256_path(Path(real))])
    skip = tuple(str(Path(x).resolve()) for x in {sys.prefix, sys.base_prefix, sys.exec_prefix}) + _SKIP_PREFIXES
    loaded, resolution = {}, {}
    for f in out["opened"]:
        try:
            os.stat(f)  # the kernel's verdict: an open that failed (and was caught) is no dependency
            links, real = walk(f)  # the as-opened path, the links traversed, the file actually read
        except OSError:
            continue
        name = os.path.basename(real)
        if os.path.isfile(real) and not real.startswith(skip) and not f.startswith(skip) and not name.endswith(_SKIP_SUFFIXES) \
                and not f.endswith(_SKIP_SUFFIXES) and name != "token":
            loaded[f] = _sha256_path(Path(real))
            resolution[f] = {"links": links, "target": real}
    body = {"code": sorted(code), "loaded": sorted([k, v] for k, v in loaded.items()), "resolution": resolution,
            "device_env": out["device_env"]}
    return {**body, "warmup": out["warmup"], "sha256": hashlib.sha256(json.dumps(body, sort_keys=True).encode()).hexdigest()}


def walk(path: str | Path, cwd: str | None = None) -> tuple[list[str], str]:
    """Resolve `path` as the kernel does: component by component, expanding
    each symlink where it is met and applying ".." to the directory reached so
    far, never to the unresolved text. A relative path is taken against `cwd`
    (default: this process's), without normalising. A missing or non-directory
    intermediate component raises (FileNotFoundError, NotADirectoryError), as
    the kernel's open would fail. Returns (every link traversed, in order, as
    the path it was met at; the real final path)."""
    p = os.fspath(path)
    if not os.path.isabs(p):
        p = os.path.join(cwd or os.getcwd(), p)
    todo, cur, links = p.split("/"), "/", []
    while todo:
        c = todo.pop(0)
        if c in ("", "."):
            continue
        if not os.path.isdir(cur):  # every component before this one must be a directory
            raise (NotADirectoryError if os.path.exists(cur) else FileNotFoundError)(f"{path}: {cur} is not a directory")
        if c == "..":
            cur = os.path.dirname(cur)
            continue
        nxt = os.path.join(cur, c)
        if os.path.islink(nxt):
            links.append(nxt)
            if len(links) > 40:
                raise SystemExit(f"{path}: too many symlinks")
            t = os.readlink(nxt)
            todo = t.split("/") + todo
            if t.startswith("/"):
                cur = "/"
            continue
        cur = nxt
    return links, cur


def write_content_identity(sdir: Path, ci: dict[str, Any], ident: dict[str, Any], backfilled: bool = False,
                           evidence: dict[str, Any] | None = None) -> dict[str, Any]:
    body = {"kind": "w0-scorer-content", "identity_sha256": ident["hash"], "scorer": ident["scorer"], "args": ident["args"],
            **ci, "backfilled": backfilled, **({"evidence": evidence} if evidence else {})}
    (Path(sdir) / "CONTENT.json").write_text(json.dumps(body, indent=1, sort_keys=True))
    return body


def backfill_content(out: Path) -> dict[str, Any]:
    """Record the content identity of a score directory written before content
    identities existed, only if every covered file (code and loaded) was last
    modified before the run's COMPLETE.json; otherwise refuse (rescore)."""
    sdir = Path(out) / "scores"
    if (sdir / "CONTENT.json").exists():
        raise SystemExit(f"{sdir}: already has a content identity")
    if not (sdir / "IDENTITY.json").exists() or not (sdir / "COMPLETE.json").exists():
        raise SystemExit(f"{sdir}: not a complete, identified score directory")
    ident = json.loads((sdir / "IDENTITY.json").read_text())
    if json.loads((sdir / "COMPLETE.json").read_text()).get("identity") != ident.get("hash"):
        raise SystemExit(f"{sdir}: COMPLETE belongs to another configuration")
    ci = content_identity(ident["scorer"], ident["args"])
    root = Path(__file__).resolve().parents[2]
    done = (sdir / "COMPLETE.json").stat().st_mtime
    covered = [p if os.path.isabs(p) else os.path.join(str(root), p) for p, _ in ci["code"]] + [p for p, _ in ci["loaded"]]
    walks = [walk(p) for p in covered]  # every traversed link by lstat, every real target by stat
    chains = [Path(q) for links, real in walks for q in links] + [Path(real) for _, real in walks]
    newer = sorted({str(q) for q in chains if (q.lstat() if q.is_symlink() else q.stat()).st_mtime > done})
    if newer:
        raise SystemExit(f"{sdir}: {len(newer)} covered files were modified after the scoring completed ({newer[:3]}); rescore")
    ev = {"rule": "every covered file's mtime precedes COMPLETE.json", "complete_mtime": done,
          "newest_covered_mtime": max((q.lstat().st_mtime for q in chains), default=None), "n_symlinks_checked": sum(len(l) for l, _ in walks),
          "git_head": _git()}
    return write_content_identity(sdir, ci, ident, backfilled=True, evidence=ev)


def expected_score_keys(fs: FrozenSet, rows: list[dict[str, Any]]) -> list[str]:
    """Every (condition, mixture) key a complete scoring run of these rows saves:
    a condition exists for a speaker iff its enrollment stream reaches k."""
    keys = []
    lens: dict[tuple[str, str, bool], int] = {}
    for r in rows:
        for device in DEVICES:
            for contaminated in (False, True):
                lk = (r["speaker"], device, contaminated)
                if lk not in lens:
                    lens[lk] = len(fs.enrollment_stream(r["speaker"], device, contaminated))
                for k in KS:
                    if lens[lk] >= k:
                        keys.append(f"{cond_key(device, contaminated, k)}|{r['id']}")
    return sorted(keys)


def _keys_hash(keys: list[str]) -> str:
    import hashlib

    return hashlib.sha256("\n".join(sorted(keys)).encode()).hexdigest()


def check_score_identity(out: Path, spec: str, kwargs: dict[str, str], set_id: str, set_hash: str, expected: list[str] | None = None) -> None:
    """Saved scores must belong to the requested scorer configuration and set
    (eval r2 #1) and be complete (eval r3 #1-2: a COMPLETE marker written only
    after scoring finished, whose key list must equal the expected coverage)."""
    p = out / "scores" / "IDENTITY.json"
    if not p.exists():
        raise SystemExit(f"{out}: no score identity; re-run scoring")
    have = json.loads(p.read_text())
    want = scorer_identity(spec, kwargs, set_id, set_hash)
    if have != want:
        raise SystemExit(f"{out}: scores belong to {have.get('scorer')} {have.get('args')} on {have.get('set_id')}, not the requested configuration")
    c = out / "scores" / "COMPLETE.json"
    if not c.exists():
        raise SystemExit(f"{out}: scoring did not complete (no COMPLETE marker)")
    done = json.loads(c.read_text())
    if done.get("identity") != want["hash"]:
        raise SystemExit(f"{out}: COMPLETE marker belongs to another configuration")
    if expected is not None and (done.get("n_keys") != len(expected) or done.get("keys_sha256") != _keys_hash(expected)):
        raise SystemExit(f"{out}: saved scores do not cover the expected {len(expected)} (condition, mixture) keys")


def prepare_score_dir(sdir: Path, want: dict[str, Any]) -> None:
    """Claim a score directory for one configuration: refuse one holding another
    configuration's identity, or any score archive without an identity (eval r3
    #1); clear a stale COMPLETE marker before scoring starts."""
    sdir.mkdir(parents=True, exist_ok=True)
    ident = sdir / "IDENTITY.json"
    if ident.exists():
        if json.loads(ident.read_text()) != want:
            raise SystemExit(f"{sdir}: holds scores of another configuration; use another --out")
    elif any(sdir.glob("*.npz")):
        raise SystemExit(f"{sdir}: holds scores without a verified identity; use another --out")
    (sdir / "COMPLETE.json").unlink(missing_ok=True)
    ident.write_text(json.dumps(want, indent=1, sort_keys=True))


def run_scoring(set_id: str, spec: str, kwargs: dict[str, str], half: str, workers: int, out: Path, root: Path | None = None) -> None:
    """Score every row of the half. Workers are fresh spawn processes, so they
    import the scorer as it is on disk when they start, as the content identity
    measured before and after scoring does (never a copy inherited from this
    process). `root` (tests) loads the set from another directory."""
    from multiprocessing import get_context

    fs = FrozenSet(set_id, root=Path(root)) if root else FrozenSet(set_id)
    rows = [r for r in fs.manifest if half == "all" or r["half"] == half]
    by_spk: dict[str, list[str]] = {}
    for r in rows:
        by_spk.setdefault(r["speaker"], []).append(r["id"])
    sdir = out / "scores"
    want = scorer_identity(spec, kwargs, set_id, fs.hash)
    prepare_score_dir(sdir, want)
    (sdir / "CONTENT.json").unlink(missing_ok=True)
    content_before = content_identity(spec, kwargs)
    jobs = [(set_id, spec, kwargs, s, ids, str(out), str(root) if root else None) for s, ids in sorted(by_spk.items(), key=lambda x: int(x[0]))]
    timing = []
    with ProcessPoolExecutor(workers, mp_context=get_context("spawn")) as ex:
        for k, t in enumerate(ex.map(_score_speaker, jobs)):
            timing.append(t)
            print(f"{k + 1}/{len(jobs)} speaker {t['speaker']} scored", flush=True)
    (out / "timing.json").write_text(json.dumps(timing))
    saved = sorted(k for spk in by_spk for k in load_scores(sdir / f"{spk}.npz"))
    expected = expected_score_keys(fs, rows)
    if saved != expected:
        raise SystemExit(f"scoring saved {len(saved)} keys, expected {len(expected)}")
    if content_identity(spec, kwargs)["sha256"] != content_before["sha256"]:
        raise SystemExit("the scorer's code or loaded files changed during scoring; refusing to mark the run complete")
    (sdir / "COMPLETE.json").write_text(json.dumps({"identity": want["hash"], "n_keys": len(saved), "keys_sha256": _keys_hash(saved)}, indent=1))
    write_content_identity(sdir, content_before, want)


def oracle_scores(fs: FrozenSet, rows: list[dict[str, Any]]) -> dict[str, np.ndarray]:
    out = {}
    for r in rows:
        lab = fs.labels(r)["labels"]
        out[r["id"]] = ((lab == 1) | (lab == 3)).astype(np.float32)
    return out


# --- metrics -----------------------------------------------------------------------------


def save_scores(path: Path, scores: dict[str, np.ndarray]) -> None:
    """Frame scores stored as float32 exactly as the scorer returned them (no
    float16: its spacing near 1 would tie confident scores where tau sits)."""
    np.savez_compressed(path, **{k: np.asarray(v, dtype=np.float32) for k, v in scores.items()})


def load_scores(path: Path) -> dict[str, np.ndarray]:
    with np.load(path) as z:
        return {k: z[k].astype(np.float32, copy=False) for k in z.files}


def _load_scores(out: Path, speakers: list[str]) -> dict[str, np.ndarray]:
    allsc: dict[str, np.ndarray] = {}
    for s in speakers:
        allsc.update(load_scores(out / "scores" / f"{s}.npz"))
    return allsc


FRAME_BOOT = 300  # bootstrap resamples for the exact frame statistics (cost)
ORACLE_WIDENINGS = (0.0, 0.05, 0.2)  # sensitivity of the oracle ceiling; the rule itself uses align.WORD_WIDEN_S


def calibration_hash(cal: dict[str, Any]) -> str:
    import hashlib

    body = {k: v for k, v in cal.items() if k != "hash"}
    return hashlib.sha256(json.dumps(body, sort_keys=True).encode()).hexdigest()


def load_calibration(path: Path) -> dict[str, Any]:
    cal = json.loads(Path(path).read_text())
    if cal.get("hash") != calibration_hash(cal):
        raise SystemExit(f"calibration artefact {path} fails its hash check")
    if cal.get("split") != "dev":
        raise SystemExit("taus must come from a dev calibration")
    return cal


def compute_metrics(set_id: str, out: Path, half: str, spec: str, boot: int = BOOT, fs: FrozenSet | None = None,
                    words: dict[str, Any] | None = None, fixed_taus: dict[str, float] | None = None) -> dict[str, Any]:
    """All metrics of one scorer on one set. Without `fixed_taus` (calibration
    mode, dev only) tau is calibrated on the set's primary headline mixtures and
    re-calibrated inside every bootstrap resample. With `fixed_taus` (apply mode,
    e.g. the sealed test set) the dev taus are used as they are, never re-fit,
    in the point estimate and in every resample (eval r1 #2)."""
    fs = fs or FrozenSet(set_id)
    split = fs.manifest[0]["meta"]["split"] if fs.manifest else "unknown"
    if fixed_taus is None and split != "dev":
        raise SystemExit(f"calibration runs on dev sets only (this set is {split}); use apply with a dev calibration")
    words = words if words is not None else read_words(set_id)
    rows = [r for r in fs.manifest if half == "all" or r["half"] == half]
    speakers = sorted({r["speaker"] for r in rows}, key=int)
    universe = sorted({s for r in rows for s in involved_speakers(r)}, key=int)
    oracle = spec == "oracle"
    if oracle:
        orc = oracle_scores(fs, rows)
    else:
        allsc = _load_scores(out, speakers)
        expected = expected_score_keys(fs, rows)
        if sorted(allsc) != expected:
            raise SystemExit(f"{out}: loaded {len(allsc)} score keys, expected {len(expected)}; incomplete or foreign scores")
    records = [words[r["id"]] for r in rows]
    tok = M.build_tokens(records, [r["scenario"] for r in rows])
    lab_all = [fs.labels(r) for r in rows]
    labels = [x["labels"] for x in lab_all]
    labels_nm = [x.get("labels_nomerge", x["labels"]) for x in lab_all]
    inv = M.involvement_matrix([involved_speakers(r) for r in rows], universe)
    scen = np.array([M.SCENARIOS.index(r["scenario"]) for r in rows])
    dropout = np.array([bool(w.get("dropout", False)) for w in records])
    # The oracle (frame labels as scores) is computed beside every scorer: the ceiling.
    orc_scores = list(oracle_scores(fs, rows).values())
    orc_led = M.Ledger(tok, M.token_means(tok, orc_scores))
    rng = np.random.default_rng(BOOT_SEED)
    boot_counts = [np.bincount(rng.integers(0, len(universe), len(universe)), minlength=len(universe)).astype(np.float64) for _ in range(boot)]
    boot_w = [M.weights_from_counts(inv, c) for c in boot_counts]
    groups = [("pooled_all", None), ("pooled_S1-S4", scen > 0), ("pooled_S1-S4_nondropout", (scen > 0) & ~dropout)] + [(sname, scen == i) for i, sname in enumerate(M.SCENARIOS)]

    conds = [(d, c, k) for d in DEVICES for c in (False, True) for k in KS]
    results: dict[str, Any] = {}
    headline_tau = fixed_taus.get(cond_key(*HEADLINE)) if fixed_taus else None
    order = [HEADLINE] + [x for x in conds if x != HEADLINE]
    for device, contaminated, k in order:
        key = cond_key(device, contaminated, k)
        if oracle:
            scores = [orc[r["id"]] for r in rows]
        else:
            scores = [allsc.get(f"{key}|{r['id']}") for r in rows]
        have = np.array([x is not None for x in scores])
        rel = np.array([r["relation_at"][str(k)] or "short" for r in rows])
        primary = np.array([r.get("rir_mode", "coherent") == "coherent" for r in rows])
        headline = have & np.isin(rel, HEADLINE_RELATIONS) & primary
        if not headline.any():
            results[key] = {"skipped": "no mixture reaches k"}
            continue
        if fixed_taus is not None and (key not in fixed_taus or fixed_taus[key] is None or not np.isfinite(fixed_taus[key])):
            results[key] = {"skipped": "not evaluable (uncalibrated on dev)"}
            continue
        scores = [x if x is not None else np.zeros(r["meta"]["frames"], np.float32) for x, r in zip(scores, rows)]
        means = M.token_means(tok, scores)
        led = M.Ledger(tok, means)
        w_head = headline.astype(np.float64)
        tau = float(fixed_taus[key]) if fixed_taus is not None else led.calibrate(w_head)
        if not np.isfinite(tau):
            results[key] = {"skipped": "uncalibrated: no correctly recognised target word in the calibration pool", "tau": None}
            continue
        if (device, contaminated, k) == HEADLINE and fixed_taus is None:
            headline_tau = tau
        res: dict[str, Any] = {"tau": tau, "tau_source": "fixed (dev calibration)" if fixed_taus is not None else "calibrated on this set",
                               "n_mixtures": int(headline.sum()), "n_speakers": len({r["speaker"] for r, h in zip(rows, headline) if h})}

        def block(w: np.ndarray, t: float, led_=led) -> dict[str, Any]:
            rem = led_.removed(t)
            return {g: led_.summarize(rem, w, msk) for g, msk in groups}

        res["point"] = block(w_head, tau)
        res["n_mixtures_by_group"] = {g: int(np.sum(headline if msk is None else headline & msk)) for g, msk in groups}
        if fixed_taus is None:
            t_o = orc_led.calibrate(w_head)
        else:
            if f"oracle|{key}" not in fixed_taus:
                raise SystemExit(f"calibration artefact lacks the oracle tau for {key}")
            t_o = float(fixed_taus[f"oracle|{key}"])
        res["oracle"] = {"tau": t_o, **block(w_head, t_o, orc_led)}
        # Bootstrap: joint speaker resampling; tau re-calibrated in each resample
        # (calibration mode) or held at the dev value (apply mode).
        draws: dict[str, list[float]] = {}
        taus = []
        for bw in boot_w:
            w = bw * w_head
            if w.sum() == 0:
                continue
            t_b = led.calibrate(w) if fixed_taus is None else tau
            if not np.isfinite(t_b):
                continue  # counted through n_resamples_used
            taus.append(t_b)
            for g, d in block(w, t_b).items():
                for mname, v in d.items():
                    if not mname.startswith("n_"):
                        draws.setdefault(f"{g}|{mname}", []).append(v)
        res["ci95"] = {kk: M.percentile_ci(np.array(v)) for kk, v in draws.items()}
        res["ci_valid_resamples"] = {kk: M.n_valid(np.array(v)) for kk, v in draws.items()}
        res["tau_ci95"] = M.percentile_ci(np.array(taus))
        res["n_resamples_used"] = len(taus)
        rem_tau = led.removed(tau)
        # By enrollment relation (headline tau); same_chapter only here.
        res["by_relation"] = {}
        for rname in ("cross_project", "same_project_cross_chapter", "same_chapter"):
            m = (have & (rel == rname) & primary).astype(float)
            if m.any():
                res["by_relation"][rname] = {"n_mixtures": int(m.sum()), **{g: led.summarize(rem_tau, m, msk) for g, msk in groups}}
        # Frame AUC / EER, exact weighted rank statistics (eval r1 #1, #3), under
        # the primary and the no-merge labels; headline condition only (cost).
        is_headline = (device, contaminated, k) == HEADLINE
        for fkey, labs in ((("frame", labels), ("frame_nomerge", labels_nm)) if is_headline else ()):
            res[fkey] = {}
            for name, msk in [("pooled_S1-S4", scen > 0)] + [(sname, scen == i) for i, sname in enumerate(M.SCENARIOS) if i > 0]:
                sel = headline & msk
                if not sel.any():
                    continue
                ii = np.flatnonzero(sel)
                fr = M.FrameRanks([scores[i] for i in ii], [labs[i] for i in ii])
                auc, eer = fr.auc_eer()
                bt = [fr.auc_eer(bw[ii]) for bw in boot_w[:FRAME_BOOT]]
                aucs, eers = np.array([x[0] for x in bt]), np.array([x[1] for x in bt])
                res[fkey][name] = {"auc": auc, "eer": eer, "auc_ci95": M.percentile_ci(aucs), "eer_ci95": M.percentile_ci(eers),
                                   "valid_resamples": M.n_valid(aucs), "of_resamples": len(bt)}
        if is_headline:
            # Oracle ceiling sensitivity to the word widening (contract: 80 ms).
            res["oracle_widening"] = {}
            nf = [int(r["meta"]["frames"]) for r in rows]
            for wd in ORACLE_WIDENINGS:
                tok_w = M.rewiden(tok, wd, nf)
                led_w = M.Ledger(tok_w, M.token_means(tok_w, orc_scores))
                wkey = f"oracle_widen{int(round(wd * 1000))}ms|{key}"
                if fixed_taus is None:
                    t_w = led_w.calibrate(w_head)
                else:  # never fitted on the evaluated set (eval r5 #1)
                    if wkey not in fixed_taus:
                        raise SystemExit(f"calibration artefact lacks {wkey}")
                    t_w = fixed_taus[wkey] if fixed_taus[wkey] is not None else float("nan")
                res["oracle_widening"][f"{int(round(wd * 1000))}ms"] = (
                    {"tau": t_w, **block(w_head, t_w, led_w)} if np.isfinite(t_w) else {"tau": None, "uncalibrated": True})
        # Secondary groupings at this condition's tau.
        unseen = np.array([not fs.plans[r["speaker"]].get("test_project_in_train", True) for r in rows])
        res["secondary"] = {}
        for gname, m in (("mixed_rir", have & np.isin(rel, HEADLINE_RELATIONS) & ~primary), ("project_unseen_in_train", headline & unseen)):
            if m.any():
                res["secondary"][gname] = {"n_mixtures": int(m.sum()), **{g: led.summarize(rem_tau, m.astype(float), msk) for g, msk in groups}}
        res["realigned_wer"] = realigned_wer(records, means, tau, headline, scen)
        if headline_tau is not None:
            rem_h = led.removed(headline_tau)
            res["at_headline_tau"] = {"tau": headline_tau, **{g: led.summarize(rem_h, w_head, msk) for g, msk in groups}}
        halves = np.array([r["half"] for r in rows])
        if fixed_taus is None and half == "all" and set(halves) >= {"A", "B"}:
            cf = {}
            for cal, ev in (("A", "B"), ("B", "A")):
                wc = (headline & (halves == cal)).astype(float)
                we = (headline & (halves == ev)).astype(float)
                t_c = led.calibrate(wc)
                if not np.isfinite(t_c):
                    cf[f"{cal}->{ev}"] = {"tau": None, "uncalibrated": True}
                    continue
                rem_c = led.removed(t_c)
                cf[f"{cal}->{ev}"] = {"tau": t_c, **{g: led.summarize(rem_c, we, msk) for g, msk in groups}}
            res["crossfit"] = cf
        results[key] = res
        print(f"{key}: tau={tau:.4f} interferer_kept(S1-S4)={res['point']['pooled_S1-S4']['interferer_kept/all']:.3f} "
              f"target_removed={res['point']['pooled_all']['target_removed/all']:.4f}", flush=True)
    return {"conditions": results, "n_bootstrap": boot, "frame_bootstrap": FRAME_BOOT, "bootstrap_seed": BOOT_SEED, "speakers": speakers,
            "universe": universe, "mode": "apply" if fixed_taus is not None else "calibrate"}


def calibration_artefact(res: dict[str, Any], spec: str, kwargs: dict[str, str], set_id: str, set_hash: str, half: str, split: str) -> dict[str, Any]:
    if split != "dev":
        raise SystemExit("calibration artefacts come from dev sets only")
    taus = {k: (v["tau"] if v.get("tau") is not None else None) for k, v in res["conditions"].items() if "tau" in v}
    taus.update({f"oracle|{k}": v["oracle"]["tau"] for k, v in res["conditions"].items() if "oracle" in v})
    for k, v in res["conditions"].items():
        for wname, ov in v.get("oracle_widening", {}).items():
            taus[f"oracle_widen{wname}|{k}"] = ov.get("tau")
    uncal = sorted(k for k, v in taus.items() if v is None or not np.isfinite(v))
    cal = {"scorer": spec, "args": dict(sorted(kwargs.items())), "set_id": set_id, "set_hash": set_hash, "half": half, "split": split,
           "budget": M.BUDGET, "taus": {k: (None if k in uncal else v) for k, v in taus.items()}, "uncalibrated": uncal, "git": _git()}
    cal["hash"] = calibration_hash(cal)
    return cal


def realigned_wer(records: list[dict[str, Any]], means: np.ndarray, tau: float, mask: np.ndarray, scen: np.ndarray) -> dict[str, float]:
    from .align import Word, align, error_counts

    err = np.zeros(len(M.SCENARIOS))
    n = np.zeros(len(M.SCENARIOS))
    pos = 0
    for m, r in enumerate(records):
        t = r["tokens"]
        keep = means[pos : pos + len(t)] >= tau
        pos += len(t)
        if not mask[m]:
            continue
        hyp = [Word(x[0], x[10], x[11]) for x, kp in zip(t, keep) if kp]
        ref = [Word(*x) for x in r["target_ref"]]
        c = error_counts(align(hyp, ref, timed=True))
        err[scen[m]] += c["S"] + c["D"] + c["I"]
        n[scen[m]] += len(ref)
    return {s: float(err[i] / n[i]) if n[i] else float("nan") for i, s in enumerate(M.SCENARIOS)}


# --- latency -------------------------------------------------------------------------------


def _verify_threads(check: dict[str, Any], when: str) -> None:
    """Refuse the measurement if the scorer changed the thread configuration (eval r2 #4)."""
    changed = {k: os.environ.get(k) for k, v in CPU_ENV.items() if os.environ.get(k) != v}
    if changed:
        raise SystemExit(f"latency refused: environment changed {when}: {changed}")
    try:
        import torch

        if torch.get_num_threads() != 1:
            raise SystemExit(f"latency refused: torch uses {torch.get_num_threads()} threads {when}")
        if torch.cuda.is_available():
            raise SystemExit(f"latency refused: CUDA visible {when}")
    except ImportError:
        pass
    check.setdefault("checks", []).append(when)


CPU_ENV = {"CUDA_VISIBLE_DEVICES": "", "OMP_NUM_THREADS": "1", "MKL_NUM_THREADS": "1", "OPENBLAS_NUM_THREADS": "1",
           "NUMEXPR_NUM_THREADS": "1", "VECLIB_MAXIMUM_THREADS": "1", "ORT_NUM_THREADS": "1", "LFSPK_CPU_LATENCY": "1"}


def latency(set_id: str, spec: str, kwargs: dict[str, str]) -> dict[str, Any]:
    """CPU latency of score() on 30 fixed dev mixtures and of update(). Must run
    in a process started with CPU_ENV (no visible GPU, one thread for OpenMP,
    MKL, OpenBLAS and ONNX Runtime via ORT_NUM_THREADS; factories can honour
    LFSPK_CPU_LATENCY). The measurement is refused if a GPU is visible or torch
    reports more than one thread; other backends' thread use is recorded as
    configured, not verified (eval r1 #8)."""
    missing = {k: v for k, v in CPU_ENV.items() if os.environ.get(k) != v}
    if missing:
        raise SystemExit(f"latency must run with CPU_ENV; differing: {sorted(missing)}")
    check: dict[str, Any] = {"env": CPU_ENV}
    try:
        import torch

        torch.set_num_threads(1)
        try:
            torch.set_num_interop_threads(1)
        except RuntimeError:
            pass
        if torch.cuda.is_available():
            raise SystemExit("latency refused: a CUDA device is visible")
        check["torch_threads"] = torch.get_num_threads()
        if check["torch_threads"] != 1:
            raise SystemExit("latency refused: torch uses more than one thread")
    except ImportError:
        check["torch_threads"] = None
    fs = FrozenSet(set_id)
    rows = sorted(fs.manifest, key=lambda r: r["id"])
    pick = [r for i, r in enumerate(rows) if i % max(1, len(rows) // LATENCY_MIXTURES) == 0][:LATENCY_MIXTURES]
    sc = load_factory(spec)(**kwargs)
    _verify_threads(check, "after scorer construction")
    per_s, upd = [], []
    for r in pick:
        stream = fs.enrollment_stream(r["speaker"], "builtin", False)
        prof = sc.enroll([fs.audio(x["file"]) for x in stream[:3]])
        a = fs.audio(r["files"]["mix"])
        sc.score(prof, a)  # warm-up
        t = time.perf_counter()
        sc.score(prof, a)
        per_s.append((time.perf_counter() - t) / (a.size / 16000))
        if len(stream) > 3:
            u = fs.audio(stream[3]["file"])
            t = time.perf_counter()
            sc.update(prof, u)
            upd.append((time.perf_counter() - t) / (u.size / 16000) * 10.0)
    _verify_threads(check, "after measurement")
    return {"threads": 1, "verified": check, "n_mixtures": len(pick), "score_s_per_audio_s": {"median": float(np.median(per_s)), "p90": float(np.quantile(per_s, 0.9))},
            "update_s_per_10s_dictation": {"median": float(np.median(upd)) if upd else None, "p90": float(np.quantile(upd, 0.9)) if upd else None}}


# --- report --------------------------------------------------------------------------------


def _fmt(p: float, ci: tuple[float, float] | None, pct: bool = True) -> str:
    if p is None or not np.isfinite(p):
        return "n/a"
    f = 100.0 if pct else 1.0
    s = f"{p * f:.2f}"
    if ci is not None and np.isfinite(ci[0]):
        s += f" [{ci[0] * f:.2f}, {ci[1] * f:.2f}]"
    return s


def report_md(res: dict[str, Any]) -> str:
    """Readable report with every computed metric family (eval r1 #10)."""
    nan2 = (float("nan"), float("nan"))
    L = [f"# {res['scorer']} on {res['set_id']} ({res['half']}, {res.get('mode')})", "",
         f"set hash `{res['set_hash']}`, git `{res.get('git')}`, calibration `{res.get('calibration_hash')}`"
         + (f" (from {res['calibration_from']})" if res.get("calibration_from") else "") + ".",
         f"Bootstrap B={res['n_bootstrap']} (frame statistics: first {res.get('frame_bootstrap')}), seed {res['bootstrap_seed']}, joint "
         f"resampling of {len(res['universe'])} LibriSpeech speakers over target and interferer roles; CIs are conditional on the fixed "
         "enrollment contamination streams.", "",
         "Percent; 95 % CI in brackets. Headline: primary (coherent-room) mixtures of targets whose enrollment relation is cross_project "
         "or same_project_cross_chapter. `kept` = interferer words kept (primary metric); `kept nd` = on mixtures without target dropout; "
         "`kept+amb` = counting tokens matched by both target and interferer as interferer; `cover` = target words correctly recognised "
         "before filtering; `removed` = correct target words removed (budget 0.5 % pooled).", ""]
    for key, c in res["conditions"].items():
        if "skipped" in c:
            L += [f"## {key}: skipped ({c['skipped']})", ""]
            continue
        ci = lambda g, m: tuple(c["ci95"].get(f"{g}|{m}", nan2))
        used = c["n_resamples_used"]
        cond_note = (f" **CIs are conditional on calibratable resamples: only {used} of {res['n_bootstrap']} draws had a finite tau.**"
                     if used < 0.95 * res["n_bootstrap"] else "")
        L += [f"## {key}", "", f"tau {c['tau']:.4f} ({c['tau_source']}; CI {c['tau_ci95']}), {c['n_mixtures']} mixtures, {c['n_speakers']} targets, "
              f"{used} of {res['n_bootstrap']} resamples used; fewest valid resamples of any statistic: "
              f"{min(c['ci_valid_resamples'].values()) if c['ci_valid_resamples'] else 'n/a'}.{cond_note}", "",
              "| group | interferer words (n) / mixtures | kept | kept nd | kept+amb | removed | cover | WER before | WER after | WER after overlap | kept overlap | AUC | EER | oracle kept / WER after |",
              "|---|---|---|---|---|---|---|---|---|---|---|---|---|---|"]
        for g in ["S0", "S1", "S2", "S3", "S4", "pooled_S1-S4", "pooled_S1-S4_nondropout", "pooled_all"]:
            p = c["point"].get(g)
            if p is None:
                continue
            fr = c.get("frame", {}).get(g, {})
            auc = _fmt(fr.get("auc"), tuple(fr.get("auc_ci95", nan2)), pct=False) if fr else "n/a"
            eer = _fmt(fr.get("eer"), tuple(fr.get("eer_ci95", nan2))) if fr else "n/a"
            o = c["oracle"][g]
            L.append(f"| {g} | {p['n_interferer/all']:.0f} / {c['n_mixtures_by_group'][g]} | {_fmt(p['interferer_kept/all'], ci(g, 'interferer_kept/all'))} | "
                     f"{_fmt(c['point'].get('pooled_S1-S4_nondropout', {}).get('interferer_kept/all') if g == 'pooled_S1-S4' else None, None)} | "
                     f"{_fmt(p['interferer_kept_incl_ambiguous/all'], ci(g, 'interferer_kept_incl_ambiguous/all'))} | "
                     f"{_fmt(p['target_removed/all'], ci(g, 'target_removed/all'))} | {_fmt(p['target_coverage/all'], ci(g, 'target_coverage/all'))} | "
                     f"{_fmt(p['wer_before/all'], ci(g, 'wer_before/all'))} | {_fmt(p['wer_after/all'], ci(g, 'wer_after/all'))} | "
                     f"{_fmt(p['wer_after/overlap'], ci(g, 'wer_after/overlap'))} | {_fmt(p['interferer_kept/overlap'], ci(g, 'interferer_kept/overlap'))} | "
                     f"{auc} | {eer} | {_fmt(o['interferer_kept/all'], None)} / {_fmt(o['wer_after/all'], None)} |")
        s0 = c["point"]["S0"]
        L += ["", f"S0 WER increase {_fmt(s0['wer_increase'], ci('S0', 'wer_increase'))} points (reported guardrail metric; oracle: "
              f"{_fmt(c['oracle']['S0']['wer_increase'], None)}); ambiguous tokens in S1-S4: "
              f"{c['point']['pooled_S1-S4']['n_ambiguous/all']:.0f}. Re-aligned WER after filtering (exact; the table's is a fixed-alignment upper bound): "
              + ", ".join(f"{k} {v * 100:.2f}" for k, v in c["realigned_wer"].items()), ""]
        for wname, v in c.get("oracle_widening", {}).items():
            if v.get("uncalibrated"):
                L.append(f"Oracle at {wname} widening: uncalibrated.")
            else:
                L.append(f"Oracle at {wname} widening (rule: 80 ms): tau {v['tau']:.3f}, kept S1-S4 {_fmt(v['pooled_S1-S4']['interferer_kept/all'], None)}, "
                         f"removed {_fmt(v['pooled_all']['target_removed/all'], None)}, S0 WER increase {_fmt(v['S0']['wer_increase'], None)}.")
        nm = c.get("frame_nomerge", {})
        if nm:
            L.append("Frame metrics under the no-merge sensitivity labels: " + "; ".join(
                f"{g} AUC {_fmt(v['auc'], tuple(v['auc_ci95']), pct=False)}, EER {_fmt(v['eer'], tuple(v['eer_ci95']))}" for g, v in nm.items()))
            L.append("")
        if "at_headline_tau" in c:
            h = c["at_headline_tau"]
            L.append(f"At the headline condition's tau {h['tau']:.4f} (one product threshold): removed {_fmt(h['pooled_all']['target_removed/all'], None)}, "
                     f"S0 WER increase {_fmt(h['S0']['wer_increase'], None)}, kept S1-S4 {_fmt(h['pooled_S1-S4']['interferer_kept/all'], None)}.")
        for rname, v in c.get("by_relation", {}).items():
            L.append(f"Relation {rname} ({v['n_mixtures']} mixtures): removed {_fmt(v['pooled_all']['target_removed/all'], None)}, "
                     f"kept S1-S4 {_fmt(v['pooled_S1-S4']['interferer_kept/all'], None)}, S0 WER increase {_fmt(v['S0']['wer_increase'], None)}.")
        for gname, v in c.get("secondary", {}).items():
            L.append(f"Secondary {gname} ({v['n_mixtures']} mixtures): removed {_fmt(v['pooled_all']['target_removed/all'], None)}, "
                     f"kept S1-S4 {_fmt(v['pooled_S1-S4']['interferer_kept/all'], None)}, WER before/after S1-S4 "
                     f"{_fmt(v['pooled_S1-S4']['wer_before/all'], None)} / {_fmt(v['pooled_S1-S4']['wer_after/all'], None)}.")
        for k2, v in c.get("crossfit", {}).items():
            if v.get("uncalibrated"):
                L.append(f"Cross-fit {k2}: uncalibrated (no correctly recognised target word in the calibration half); not evaluable.")
                continue
            L.append(f"Cross-fit {k2} (tau {v['tau']:.4f}): removed {_fmt(v['pooled_all']['target_removed/all'], None)}, kept S1-S4 "
                     f"{_fmt(v['pooled_S1-S4']['interferer_kept/all'], None)}, S0 WER increase {_fmt(v['S0']['wer_increase'], None)}.")
        L.append("")
    if res.get("latency"):
        L += [f"CPU latency (one thread, verified env): {json.dumps(res['latency'])}", ""]
    if res.get("throughput"):
        L += [f"Throughput (parallel workers): {json.dumps(res['throughput'])}", ""]
    if res.get("cost"):
        L += [f"CostReport: {json.dumps(res['cost'])}", ""]
    return "\n".join(L)


def _git() -> str:
    try:
        return subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=Path(__file__).resolve().parents[2], text=True).strip()
    except Exception:
        return "unknown"


def main(argv: list[str] | None = None) -> None:
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    bf = sub.add_parser("backfill-content", help="record the content identity of a score directory written before content identities")
    bf.add_argument("--out", type=Path, required=True)
    for name in ("run", "metrics", "latency", "apply"):
        p = sub.add_parser(name)
        p.add_argument("--calibration", type=Path, default=None, help="apply: dev calibration artefact (calibration.json)")
        p.add_argument("--set", required=True)
        p.add_argument("--scorer", required=True)
        p.add_argument("--arg", action="append", default=[])
        p.add_argument("--half", default="all", choices=["all", "A", "B"])
        p.add_argument("--workers", type=int, default=8)
        p.add_argument("--out", type=Path, default=None)
        p.add_argument("--boot", type=int, default=BOOT)
        p.add_argument("--name", default=None, help="result directory name (default: scorer name)")
    a = ap.parse_args(argv)
    paths.require_mount()
    if a.cmd == "backfill-content":
        print(json.dumps({k: v for k, v in backfill_content(a.out).items() if k in ("sha256", "backfilled", "evidence", "warmup")}))
        return
    kwargs = parse_args_kv(a.arg)
    fs = FrozenSet(a.set)
    if a.cmd == "latency":
        print(json.dumps(latency(a.set, a.scorer, kwargs)))
        return
    name = a.name or (a.scorer if a.scorer == "oracle" else getattr(load_factory(a.scorer)(**kwargs), "name", a.scorer))
    out = a.out or paths.RUNS / "W0" / "eval" / name / f"{a.set}-{a.half}"
    out.mkdir(parents=True, exist_ok=True)
    t0 = time.time()
    split = fs.manifest[0]["meta"]["split"]
    fixed = None
    if a.cmd == "apply":
        if a.calibration is None:
            raise SystemExit("apply needs --calibration (a dev calibration.json)")
        cal = load_calibration(a.calibration)
        if cal["scorer"] != a.scorer or cal["args"] != dict(sorted(kwargs.items())):
            raise SystemExit("calibration artefact belongs to another scorer configuration")
        fixed = cal["taus"]
    elif split != "dev":
        raise SystemExit(f"calibration runs on dev sets only (this set is {split}); use apply with a dev calibration")
    if a.cmd in ("run", "apply") and a.scorer != "oracle":
        run_scoring(a.set, a.scorer, kwargs, a.half, a.workers, out)
    if a.scorer != "oracle":
        rows_h = [r for r in fs.manifest if a.half == "all" or r["half"] == a.half]
        check_score_identity(out, a.scorer, kwargs, a.set, fs.hash, expected_score_keys(fs, rows_h))
    res = compute_metrics(a.set, out, a.half, a.scorer, a.boot, fixed_taus=fixed)
    res.update({"scorer": a.scorer, "name": name, "args": kwargs, "set_id": a.set, "set_hash": fs.hash, "half": a.half, "git": _git(),
                "elapsed_s": time.time() - t0, "command": " ".join(sys.argv)})
    if fixed is None:
        cal = calibration_artefact(res, a.scorer, kwargs, a.set, fs.hash, a.half, split)
        (out / "calibration.json").write_text(json.dumps(cal, indent=1, sort_keys=True))
        res["calibration_hash"] = cal["hash"]
    else:
        res["calibration_hash"] = cal["hash"]
        res["calibration_from"] = {"set_id": cal["set_id"], "set_hash": cal["set_hash"], "half": cal["half"]}
    if a.scorer != "oracle":
        sc = load_factory(a.scorer)(**kwargs)
        c = sc.cost()
        res["cost"] = {k: (list(v) if isinstance(v, tuple) else v) for k, v in c.__dict__.items()}
        if a.cmd == "run" and split == "dev":
            env = {**os.environ, **CPU_ENV}
            lat = subprocess.run([sys.executable, "-m", "lfspk.harness.evaluate", "latency", "--set", a.set, "--scorer", a.scorer]
                                 + sum((["--arg", x] for x in a.arg), []), env=env, capture_output=True, text=True)
            res["latency"] = json.loads(lat.stdout.strip().splitlines()[-1]) if lat.returncode == 0 else {"error": lat.stderr[-2000:]}
        timing = out / "timing.json"
        if timing.exists():
            t = json.loads(timing.read_text())
            res["throughput"] = {"score_s_per_audio_s_parallel_workers": sum(x["score_s"] for x in t) / max(1e-9, sum(x["score_audio_s"] for x in t))}
    (out / "results.json").write_text(json.dumps(res, indent=1, default=float))
    (out / "results.md").write_text(report_md(res))
    print(f"wrote {out / 'results.json'}")


if __name__ == "__main__":
    sys.exit(main())
