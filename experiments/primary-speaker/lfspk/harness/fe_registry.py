"""The confirmatory-checkpoint registration, run events and the run ledger
(DESIGN.md 14.2 fe-10).

Registration. W5's `lfspk/extract/RESULTS.md` holds one line
`    confirmatory-checkpoint: R1-s0 sha256=<hex>`, recorded by exactly one
dedicated anchor commit whose message contains
`REGISTER confirmatory-checkpoint R1-s0 <hex>`. That commit's diff against its
single parent must turn exactly the placeholder line into the valid line. Only
the committed state counts: an uncommitted edit of the file refuses.

What this guarantees: the anchor, the per-artefact run binding and the ledger
catch accidental out-of-order runs in this checkout. They do not prove that no
dev evaluation happened earlier. A deleted or edited ledger, another checkout
or another machine goes undetected; procedure and the orchestrator's audit
cover that. A rebase changes the anchor's id and so invalidates every artefact
that recorded it.
"""

from __future__ import annotations

import datetime as _dt
import hashlib
import json
import os
import re
import subprocess
import uuid
from pathlib import Path
from typing import Any

REPO = Path(__file__).resolve().parents[2]
RESULTS = "lfspk/extract/RESULTS.md"
TAG = "REGISTER confirmatory-checkpoint R1-s0 "
TAG_RE = re.compile(r"REGISTER confirmatory-checkpoint R1-s0 ([0-9a-f]{64})(?![0-9a-f])")
LINE_RE = re.compile(r"^\s*confirmatory-checkpoint: R1-s0 sha256=([0-9a-f]{64})$")
PLACEHOLDER = "    confirmatory-checkpoint: R1-s0 sha256=<to be recorded after training>"


class RegistrationError(SystemExit):
    """The registration is malformed; nothing may run as if it were valid."""


def git_env() -> dict[str, str]:
    """A sanitised environment for git: no inherited GIT_* variable (GIT_DIR,
    GIT_WORK_TREE, GIT_INDEX_FILE, ... could redirect git to another
    repository), no system or global configuration, C locale, no pager."""
    env = {k: v for k, v in os.environ.items() if not k.startswith("GIT_")}
    env.update(LC_ALL="C", GIT_PAGER="cat", GIT_CONFIG_NOSYSTEM="1", GIT_CONFIG_GLOBAL=os.devnull, GIT_TERMINAL_PROMPT="0")
    return env


def _git(repo: Path, *args: str, check: bool = True, text: bool = True) -> subprocess.CompletedProcess:
    """git with the sanitised environment. The global safe.directory trust is
    gone with the global configuration, so this one repository (its canonical
    path) is trusted for this one command (code12-r2 #1)."""
    safe = os.path.realpath(repo)
    return subprocess.run(["git", "-c", f"safe.directory={safe}", *args], cwd=repo, capture_output=True, text=text, check=check,
                          env=git_env())


def _valid_lines(text: str) -> list[tuple[str, str]]:
    return [(ln, m.group(1)) for ln in text.splitlines() if (m := LINE_RE.match(ln))]


ANY_LINE_RE = re.compile(r"^\s*confirmatory-checkpoint:")


def _diff_lines(diff: str) -> tuple[list[str], list[str]]:
    """(removed, added) lines of a one-file --unified=0 diff. The file header
    (everything before the first hunk) is parsed apart, so changed lines that
    themselves begin with "--" or "++" are counted."""
    lines = diff.splitlines()
    first = next((i for i, d in enumerate(lines) if d.startswith("@@")), len(lines))
    if sum(d.startswith("diff --git") for d in lines[:first]) > 1:
        raise RegistrationError("the anchor diff must cover one file")
    removed, added = [], []
    for d in lines[first:]:
        if d.startswith("@@"):
            continue
        if d.startswith("\\"):
            continue  # "\ No newline at end of file"
        if d.startswith("-"):
            removed.append(d[1:])
        elif d.startswith("+"):
            added.append(d[1:])
        else:
            raise RegistrationError(f"unexpected line in the anchor diff: {d[:40]!r}")
    return removed, added


def is_ancestor(repo: Path, a: str, b: str) -> bool:
    """True if commit a is an ancestor of b, or equal to it."""
    return _git(repo, "merge-base", "--is-ancestor", a, b, check=False).returncode == 0


SUP_TAG = "SUPERSEDE confirmatory-checkpoint R1-s0 "
SUP_TAG_RE = re.compile(r"SUPERSEDE confirmatory-checkpoint R1-s0 ([0-9a-f]{64})(?![0-9a-f])")
SUP_LINE = "    superseded-checkpoint: R1-s0 sha256={}"
SUP_LINE_RE = re.compile(r"^    superseded-checkpoint: R1-s0 sha256=([0-9a-f]{64})$")
ANY_SUP_RE = re.compile(r"^\s*superseded-checkpoint:")


def _default_ledger() -> Path:
    from .. import paths

    return paths.RUNS / "W0" / "frontend" / "LEDGER.jsonl"


def _anchor_diff(repo: Path, commit: str) -> tuple[list[str], list[str]]:
    parents = _git(repo, "rev-list", "--parents", "-n", "1", commit).stdout.split()[1:]
    if len(parents) != 1:
        raise RegistrationError(f"anchor {commit[:12]} must have a single parent")
    diff = _git(repo, "diff", "--unified=0", "--no-color", "--no-ext-diff", "--no-textconv", "--no-renames", parents[0], commit,
                "--", RESULTS).stdout
    return _diff_lines(diff)


def current_registration(repo: Path = REPO, ledger: Path | None = None) -> dict[str, Any] | None:
    """The registration identity {sha256, anchor, blob} (plus `superseded`
    when earlier registrations were superseded), or None while no checkpoint is
    registered. Any malformed state raises RegistrationError.

    History: a strictly ordered chain of dedicated single-parent anchor commits
    REGISTER, SUPERSEDE, REGISTER, ... in HEAD's history. A REGISTER turns
    exactly the placeholder line into the valid line of its tagged SHA-256. A
    SUPERSEDE (tag `SUPERSEDE confirmatory-checkpoint R1-s0 <old>`) names the
    SHA the preceding REGISTER registered and turns exactly its valid line into
    the placeholder plus one `superseded-checkpoint` line; it is valid only if
    the run ledger (`ledger`, default the evaluator's) holds no stage-B event,
    started or complete, of that checkpoint. A superseded SHA is never
    registered again. HEAD's file must hold exactly what the chain implies."""
    repo = Path(repo)
    if _git(repo, "rev-parse", "--is-shallow-repository").stdout.strip() != "false":
        raise RegistrationError("a shallow clone can hide an anchor commit; use a full clone")
    head_raw = _git(repo, "show", f"HEAD:{RESULTS}", text=False).stdout
    if (repo / RESULTS).read_bytes() != head_raw:
        raise RegistrationError(f"{RESULTS} has uncommitted changes; the registration counts only when committed")
    head_text = head_raw.decode("utf-8")
    log = lambda tag: [c for c in _git(repo, "log", "--format=%H", "--fixed-strings", f"--grep={tag}", "HEAD").stdout.split() if c]
    regs, sups = log(TAG), log(SUP_TAG)
    if set(regs) & set(sups):
        raise RegistrationError("one commit carries both a REGISTER and a SUPERSEDE tag")
    chain = [(c, "R") for c in regs] + [(c, "S") for c in sups]
    for c, _ in chain:
        if not is_ancestor(repo, c, "HEAD"):
            raise RegistrationError("an anchor commit is not an ancestor of HEAD")
    # strict order by ancestry (anchors are few); incomparable anchors refuse
    ordered = []
    for item in chain:
        k = 0
        while k < len(ordered) and is_ancestor(repo, ordered[k][0], item[0]):
            k += 1
        ordered.insert(k, item)
    for x, y in zip(ordered, ordered[1:]):
        if x[0] == y[0] or not is_ancestor(repo, x[0], y[0]):
            raise RegistrationError("the anchor commits must form one strictly ordered chain")
    kinds = "".join(k for _, k in ordered)
    if kinds and not ("RS" * len(kinds))[: len(kinds)] == kinds:
        raise RegistrationError(f"the anchors must alternate REGISTER, SUPERSEDE, ... (found {kinds})")
    stage_b = None
    registered, superseded = None, []
    for commit, kind in ordered:
        removed, added = _anchor_diff(repo, commit)
        body = _git(repo, "log", "-1", "--format=%B", commit).stdout
        if kind == "R":
            lines = [m.group(1) for m in (LINE_RE.match(l) for l in added) if m]
            tags = TAG_RE.findall(body)
            if removed != [PLACEHOLDER] or len(added) != 1 or len(lines) != 1 or tags != lines:
                raise RegistrationError(f"REGISTER {commit[:12]} must change exactly the placeholder line into the valid line of its tagged SHA")
            if lines[0] in [x["sha256"] for x in superseded]:
                raise RegistrationError("a superseded checkpoint cannot be registered again")
            post = _valid_lines(_git(repo, "show", f"{commit}:{RESULTS}").stdout)
            if [ln for ln, _ in post] != [added[0]]:  # the anchor's post-image holds exactly this one valid line
                raise RegistrationError(f"REGISTER {commit[:12]}: its post-image must hold exactly the registered line")
            registered = {"sha256": lines[0], "anchor": commit, "line": added[0]}
        else:
            old = SUP_TAG_RE.findall(body)
            if registered is None or old != [registered["sha256"]]:
                raise RegistrationError(f"SUPERSEDE {commit[:12]} must name the checkpoint the preceding REGISTER registered")
            if removed != [registered["line"]] or sorted(added) != sorted([PLACEHOLDER, SUP_LINE.format(old[0])]):
                raise RegistrationError(f"SUPERSEDE {commit[:12]} must turn exactly the valid line into the placeholder plus one superseded line")
            if stage_b is None:
                stage_b = [e for e in read_ledger(ledger or _default_ledger()) if e.get("stage") == "B"]
            # Only runs that began before the SUPERSEDE commit veto it: a run whose evaluation HEAD is not a
            # descendant of the anchor. A complete event is judged by its start's HEAD; a complete without
            # its start, or a run without a HEAD, counts as before (conservative).
            heads = {e.get("run_id"): e.get("head") for e in stage_b if e.get("event", "start") == "start"}
            for e in stage_b:
                if e.get("checkpoint_sha256") != old[0]:
                    continue
                head = e.get("head") if e.get("event", "start") == "start" else heads.get(e.get("run_id"))
                if not head or not is_ancestor(repo, commit, head):
                    raise RegistrationError(f"{old[0][:12]} has stage-B events from before its supersession "
                                            f"(run {e.get('run_id')}): it was evaluated and cannot be superseded")
            superseded.append({"sha256": old[0], "register": registered["anchor"], "supersede": commit})
            registered = None
    # HEAD's file must hold exactly what the chain implies
    valid = [l for l in head_text.splitlines() if LINE_RE.match(l)]
    mentions = [l for l in head_text.splitlines() if ANY_LINE_RE.match(l)]
    sup_head = sorted(l for l in head_text.splitlines() if ANY_SUP_RE.match(l))  # every mention, malformed included
    if sup_head != sorted(SUP_LINE.format(x["sha256"]) for x in superseded):
        raise RegistrationError(f"{RESULTS}'s superseded-checkpoint lines differ from the SUPERSEDE commits")
    if registered is None:
        if mentions != [PLACEHOLDER]:
            raise RegistrationError(f"{RESULTS} must hold exactly the placeholder (no checkpoint registered); found {mentions}")
        return None
    if valid != [registered["line"]] or len(mentions) != 1:
        raise RegistrationError(f"{RESULTS} must hold exactly the registered line at HEAD")
    blob = _git(repo, "rev-parse", f"{registered['anchor']}:{RESULTS}").stdout.strip()
    out = {"sha256": registered["sha256"], "anchor": registered["anchor"], "blob": blob}
    if superseded:
        out["superseded"] = superseded
    return out


def run_event(repo: Path = REPO) -> dict[str, Any]:
    """One evaluation run: random id, UTC start, evaluation HEAD, clean tree."""
    head = _git(repo, "rev-parse", "HEAD").stdout.strip()
    dirty = _git(repo, "status", "--porcelain", "--untracked-files=no").stdout.strip()
    return {"run_id": uuid.uuid4().hex, "utc": _dt.datetime.now(_dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
            "head": head, "clean": not dirty}


LEDGER = None  # default path set by the evaluator: runs/W0/frontend/LEDGER.jsonl


def append_ledger(path: Path, entry: dict[str, Any]) -> None:
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    with open(path, "a") as f:
        f.write(json.dumps(entry, sort_keys=True) + "\n")


def read_ledger(path: Path) -> list[dict[str, Any]]:
    p = Path(path)
    return [json.loads(l) for l in p.read_text().splitlines() if l.strip()] if p.exists() else []


def ledger_sha256(path: Path) -> str:
    p = Path(path)
    return hashlib.sha256(p.read_bytes() if p.exists() else b"").hexdigest()


__all__ = ["RESULTS", "TAG", "PLACEHOLDER", "RegistrationError", "is_ancestor", "current_registration", "run_event",
           "append_ledger", "read_ledger", "ledger_sha256"]
